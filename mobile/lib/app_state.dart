// Everything the app remembers and the sync rules around it.
//
// The sync rules follow web/studio.js: every edit saves on its own (no save
// button), the profile goes to the host first, then onto the character this
// phone is bound to. Binding happens through a character QR (`claim`), a seat
// QR (`seat`) or a room-code pickup in the lobby.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account.dart';
import 'api.dart';
import 'avatar.dart';
import 'faces.dart';
import 'link.dart';

enum SyncState { idle, saving, savedLocally, synced, joined, warning }

class AppState extends ChangeNotifier {
  final SharedPreferences prefs;
  final GameNightApi Function(Uri base) apiFactory;

  /// GameNight online: the account and hosted rooms.
  final CloudApi cloud;

  AppState(this.prefs, {GameNightApi Function(Uri base)? apiFactory, CloudApi? cloud})
      : apiFactory = apiFactory ?? ((base) => GameNightApi(base)),
        cloud = cloud ?? CloudApi() {
    profileId = prefs.getString('profile_id') ?? _newProfileId();
    prefs.setString('profile_id', profileId);
    name = prefs.getString('player_name') ?? randomName();
    skinColor = prefs.getString('skin_color') ?? defaultSkin;
    clothingColor = prefs.getString('clothing_color') ?? '#55a0ff';
    face = decodeAvatar(prefs.getString('face')) ?? randomFace();
    // Keep the first random name and face, so a restart is still you.
    prefs.setString('player_name', name);
    prefs.setString('face', encodeAvatar(face));
    _loadArtworks();
    boundPlayer = prefs.getString('bound_player');
    final host = prefs.getString('host');
    if (host != null) _api = this.apiFactory(Uri.parse(host));
    this.cloud.token = prefs.getString('cloud_token');
    accountEmail = prefs.getString('account_email');
    _studioRevision = prefs.getInt('studio_revision') ?? 0;
    inHostedRoom = prefs.getBool('hosted_room') ?? false;
  }

  static String _newProfileId() {
    final rng = Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return 'prof_${List.generate(9, (_) => chars[rng.nextInt(chars.length)]).join()}';
  }

  late final String profileId;
  late String name;
  late String skinColor;
  late String clothingColor;
  late Pixels face;

  GameNightApi? _api;
  GameNightApi? get api => _api;
  Uri? get host => _api?.base;

  String? boundPlayer;
  String? claim;
  int? claimSeat;
  int linkRevision = 0;

  SessionInfo? session;
  String? sessionError;

  /// The current game's phone screen, while there is one.
  Companion? companion;

  SyncState sync = SyncState.idle;
  String syncMessage = '';

  Timer? _saveTimer;
  Timer? _poll;
  bool _saving = false, _savePending = false;

  // ---- Saved faces ------------------------------------------------------

  final List<Artwork> artworks = [];
  late String currentArtworkId;

  void _loadArtworks() {
    try {
      final list = jsonDecode(prefs.getString('artworks') ?? '[]') as List;
      artworks.addAll(list.map(Artwork.fromJson).whereType<Artwork>());
    } catch (_) {}
    final current = prefs.getString('current_artwork');
    final match = artworks.where((a) => a.id == current);
    if (match.isNotEmpty) {
      currentArtworkId = match.first.id;
      face = List.of(match.first.data);
    } else {
      // The face from before saved faces existed becomes the first one.
      final art =
          Artwork(id: newArtworkId(), name: 'Sketch ${artworks.length + 1}', data: List.of(face));
      artworks.add(art);
      currentArtworkId = art.id;
      _saveArtworks();
    }
  }

  void _saveArtworks() {
    prefs.setString('artworks', jsonEncode([for (final a in artworks) a.toJson()]));
    prefs.setString('current_artwork', currentArtworkId);
  }

  Artwork get currentArtwork => artworks.firstWhere((a) => a.id == currentArtworkId);

  /// Load a saved face into the editor; it becomes your character's face.
  void selectArtwork(String id) {
    final art = artworks.where((a) => a.id == id).firstOrNull;
    if (art == null) return;
    currentArtworkId = id;
    face = List.of(art.data);
    prefs.setString('face', encodeAvatar(face));
    _saveArtworks();
    scheduleSave();
  }

  void newArtwork({Pixels? data, String? name}) {
    final art = Artwork(
        id: newArtworkId(),
        name: name ?? 'Sketch ${artworks.length + 1}',
        data: data ?? randomFace());
    artworks.add(art);
    _saveArtworks();
    selectArtwork(art.id);
  }

  void cloneArtwork(String id) {
    final source = artworks.where((a) => a.id == id).firstOrNull;
    if (source != null) newArtwork(data: List.of(source.data), name: '${source.name} copy');
  }

  void deleteArtwork(String id) {
    artworks.removeWhere((a) => a.id == id);
    if (artworks.isEmpty) return newArtwork();
    if (currentArtworkId == id) return selectArtwork(artworks.first.id);
    _saveArtworks();
    notifyListeners();
  }

  /// A backup of every face, the name and the skin colour, as text the
  /// player can keep in a note. Same format as the browser studio's.
  String exportBackup() => encodeBackup(Backup(
      username: name, skinColor: skinColor, activeArtworkId: currentArtworkId, artworks: artworks));

  /// Adds the faces from a backup (skipping ones already here) and takes its
  /// name and skin. Returns how many faces were new.
  int importBackup(String text) {
    final backup = decodeBackup(text);
    var added = 0;
    String? active;
    for (final incoming in backup.artworks) {
      final key = encodeAvatar(incoming.data);
      var same =
          artworks.where((a) => a.name == incoming.name && encodeAvatar(a.data) == key).firstOrNull;
      if (same == null) {
        same = Artwork(id: newArtworkId(), name: incoming.name, data: incoming.data);
        artworks.add(same);
        added++;
      }
      if (incoming.id == backup.activeArtworkId) active = same.id;
    }
    name = backup.username;
    prefs.setString('player_name', name);
    skinColor = backup.skinColor;
    prefs.setString('skin_color', skinColor);
    _saveArtworks();
    selectArtwork(active ?? currentArtworkId);
    return added;
  }

  /// Give your character back to the room. The phone keeps your faces and
  /// can sign in again with a room code or a character QR.
  Future<void> leaveCharacter() async {
    final api = _api, player = session?.playerId ?? boundPlayer;
    if (api == null || player == null) return;
    await api.unlink(player);
    _clearClaim();
    companion = null;
    await refreshSession();
  }

  Profile get profile =>
      Profile(id: profileId, username: name, skinColor: skinColor, avatar: encodeAvatar(face));

  // ---- Editing ---------------------------------------------------------

  void setName(String value) {
    name = value;
    if (value.trim().isNotEmpty) prefs.setString('player_name', value);
    scheduleSave();
  }

  void setSkin(String color) {
    skinColor = color;
    prefs.setString('skin_color', color);
    scheduleSave();
  }

  /// Clothing is chosen by each game; this only tints the preview.
  void setClothing(String color) {
    clothingColor = color;
    prefs.setString('clothing_color', color);
    notifyListeners();
  }

  void setFace(Pixels pixels) {
    face = pixels;
    prefs.setString('face', encodeAvatar(pixels));
    currentArtwork.data = List.of(pixels);
    _saveArtworks();
    scheduleSave();
  }

  void scheduleSave() {
    _saveTimer?.cancel();
    _status(SyncState.saving, 'Saving…');
    _saveTimer = Timer(const Duration(milliseconds: 400), pushProfile);
  }

  void _status(SyncState state, String message) {
    sync = state;
    syncMessage = message;
    notifyListeners();
  }

  /// Sends the profile to the host and onto this phone's character.
  Future<void> pushProfile() async {
    if (_saving) {
      _savePending = true;
      return;
    }
    unawaited(_pushAccount());
    final api = _api;
    if (api == null) {
      _status(SyncState.savedLocally,
          signedIn ? 'Saved on your phone and your account' : 'Saved on your phone');
      return;
    }
    _saving = true;
    try {
      await api.saveProfile(profile);
      final target = claim ?? boundPlayer;
      if (target == null && claimSeat == null) {
        _status(SyncState.savedLocally, 'Saved on your phone');
        return;
      }
      final result =
          await api.join(profileId, claim: target, seat: claimSeat, linkRevision: linkRevision);
      switch (result.status) {
        case 'unlinked':
          _clearClaim();
          _status(
              SyncState.savedLocally, 'Controller unlinked. Your character is kept on this phone.');
          return;
        case 'no_such_seat':
          _status(SyncState.warning, result.message ?? 'Nobody is on that seat any more.');
          return;
        case 'already_signed_in':
          claim = result.playerId;
          claimSeat = null;
          _bind(result.playerId);
          linkRevision = 0;
          _status(
              SyncState.warning, 'Already connected. Your edits update your existing character.');
          _savePending = true;
          return;
      }
      _bind(result.playerId);
      _status(target != null ? SyncState.synced : SyncState.joined,
          target != null ? 'Synced to your character' : 'Joined the party');
      unawaited(refreshSession());
    } on ApiError catch (e) {
      _status(SyncState.warning, e.message);
    } finally {
      _saving = false;
      if (_savePending) {
        _savePending = false;
        unawaited(pushProfile());
      }
    }
  }

  void _bind(String? player) {
    if (player == null) return;
    boundPlayer = player;
    prefs.setString('bound_player', player);
  }

  void _clearClaim() {
    claim = null;
    claimSeat = null;
    linkRevision = 0;
    boundPlayer = null;
    prefs.remove('bound_player');
  }

  // ---- Connecting -------------------------------------------------------

  /// Opens a scanned or typed lobby link. Returns a message for the user.
  Future<String> connect(HostLink link) async {
    if (link.hosted) {
      if (link.pair != null) return claimHostedSeat(link.pair!);
      if (link.roomCode != null) return joinHostedRoom(link.roomCode!);
      throw const LinkError('Enter the room code shown on the TV.');
    }
    final api = apiFactory(link.base);
    await api.ping();
    final changedHost = _api?.base != link.base;
    _api?.close();
    _api = api;
    await prefs.setString('host', link.base.toString());
    if (changedHost) _clearClaim();
    if (link.claim != null || link.seat != null) {
      claim = link.claim;
      claimSeat = link.seat;
      linkRevision = link.linkRevision;
    }
    startPolling();
    await api.saveProfile(profile);
    if (link.roomCode != null) return joinRoom(link.roomCode!);
    await pushProfile();
    if (link.claim != null || link.seat != null) return 'Connected to your character.';
    return 'Connected. Enter the room code from the lobby to pick up a character.';
  }

  Future<void> disconnect() async {
    _poll?.cancel();
    _api?.close();
    _api = null;
    session = null;
    companion = null;
    sessionError = null;
    _clearClaim();
    await prefs.remove('host');
    _status(SyncState.savedLocally, 'Saved on your phone');
  }

  Future<String> joinRoom(String code, {bool remember = false}) async {
    final api = _api;
    if (api == null) throw const ApiError('Connect to a GameNight first.');
    await api.saveProfile(profile);
    await api.joinRoom(code.toUpperCase(), profileId, remember: remember);
    await refreshSession();
    return 'Walk your character to your profile door in the lobby to connect.';
  }

  Future<void> cancelPickup() async {
    await _api?.cancelPickup(profileId);
    await refreshSession();
  }

  Future<void> setRemember(bool value) async {
    await _api?.remember(profileId, value);
    await refreshSession();
  }

  Future<void> setMainPlayer(bool value) async {
    await _api?.mainPlayer(profileId, value);
    await refreshSession();
  }

  void startPolling() {
    _poll?.cancel();
    unawaited(_refreshAll());
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _refreshAll());
  }

  Future<void> _refreshAll() async {
    await refreshSession();
    if (inHostedRoom) await refreshHostedRoom();
  }

  Future<void> refreshSession() async {
    final api = _api;
    if (api == null) return;
    try {
      final next = await api.session(profileId);
      final wasLinked = session?.linked ?? false;
      session = next;
      sessionError = null;
      if (next.linked && next.playerId != null) {
        _bind(next.playerId);
        claim = next.playerId;
        claimSeat = null;
        linkRevision = next.linkRevision;
        // A lobby pickup links us without a save from this phone; push the
        // latest drawing so the character matches what is on screen.
        if (!wasLinked) unawaited(pushProfile());
      }
      companion = next.linked ? await api.companion(profileId) : null;
    } on ApiError catch (e) {
      sessionError = e.message;
    }
    if (_disposed) return;
    notifyListeners();
  }

  // ---- GameNight account ----------------------------------------------

  String? accountEmail;
  Account? account;
  int _studioRevision = 0;
  bool _pushingAccount = false, _accountPending = false;

  bool get signedIn => cloud.signedIn;

  /// Step 1 of signing in: GameNight emails a code to [email].
  Future<void> requestSignInCode(String email) async {
    await cloud.requestCode(email);
    accountEmail = email.trim().toLowerCase();
    await prefs.setString('account_email', accountEmail!);
  }

  /// Step 2: the emailed code signs this phone in. The player saved on the
  /// account comes to the phone (faces are merged, nothing is lost), and the
  /// result is saved back.
  Future<String> verifySignInCode(String code) async {
    await cloud.verifyCode(code);
    await prefs.setString('cloud_token', cloud.token!);
    try {
      account = await cloud.me();
      final doc = await cloud.studio();
      final adopted = _adoptStudio(doc);
      await _pushAccount();
      notifyListeners();
      return adopted
          ? 'Signed in. Your saved player is on this phone now.'
          : 'Signed in. Your player is saved to your account.';
    } on SignedOut {
      await _forgetAccount();
      rethrow;
    }
  }

  /// Takes the account's name, skin and faces. False for a new account.
  bool _adoptStudio(StudioDocument doc) {
    _setStudioRevision(doc.revision);
    final workspace = doc.workspace;
    // A new account only has a placeholder name; this phone's player wins.
    if (workspace == null) return false;
    try {
      importBackup(jsonEncode({
        'username': doc.displayName ?? name,
        'skinColor': doc.skinColor ?? skinColor,
        ...workspace,
      }));
      if (doc.displayName != null && doc.displayName!.trim().isNotEmpty) {
        name = doc.displayName!;
        prefs.setString('player_name', name);
      }
      if (doc.skinColor != null) {
        skinColor = doc.skinColor!;
        prefs.setString('skin_color', skinColor);
      }
      return true;
    } on Exception {
      return false;
    }
  }

  void _setStudioRevision(int revision) {
    _studioRevision = revision;
    prefs.setInt('studio_revision', revision);
  }

  /// Saves the player and every face to the account.
  Future<void> _pushAccount() async {
    if (!cloud.signedIn) return;
    if (_pushingAccount) {
      _accountPending = true;
      return;
    }
    _pushingAccount = true;
    try {
      Future<StudioDocument?> save() => cloud.saveStudio(
          revision: _studioRevision,
          displayName: name.trim().isEmpty ? 'Player' : name.trim(),
          skinColor: skinColor,
          avatar: encodeAvatar(face),
          workspace: jsonDecode(exportBackup()) as Map<String, dynamic>);
      var saved = await save();
      if (saved == null) {
        // Another device saved first. This phone is the one being edited
        // right now, so its player wins; the other device reloads it.
        _setStudioRevision((await cloud.studio()).revision);
        saved = await save();
      }
      if (saved != null) _setStudioRevision(saved.revision);
    } on SignedOut {
      await _forgetAccount();
      _status(SyncState.warning, 'Your sign-in expired. Sign in again to keep your player online.');
    } on ApiError catch (e) {
      _status(SyncState.warning, e.message);
    } finally {
      _pushingAccount = false;
      if (_accountPending) {
        _accountPending = false;
        unawaited(_pushAccount());
      }
    }
  }

  Future<void> signOut() async {
    await cloud.signOut();
    await _forgetAccount();
    notifyListeners();
  }

  Future<void> _forgetAccount() async {
    cloud.token = null;
    account = null;
    hostedRoom = null;
    inHostedRoom = false;
    await prefs.remove('cloud_token');
    await prefs.remove('hosted_room');
    await prefs.remove('studio_revision');
    _studioRevision = 0;
  }

  /// Loads the account on startup, so the name shows and the token is known
  /// to still work.
  Future<void> loadAccount() async {
    if (!cloud.signedIn) return;
    try {
      account = await cloud.me();
      if (inHostedRoom) startPolling();
    } on SignedOut {
      await _forgetAccount();
    } on ApiError {
      // Offline: keep the token and try again later.
    }
    notifyListeners();
  }

  // ---- Hosted rooms (joined by room code over the internet) ------------

  bool inHostedRoom = false;
  HostedRoom? hostedRoom;

  /// The phone needs an account for hosted rooms.
  static const signInFirst = ApiError('Sign in to join a room with its code.');

  Future<String> joinHostedRoom(String code, {bool remember = false}) async {
    if (!cloud.signedIn) throw signInFirst;
    await _pushAccount();
    await cloud.joinRoom(code.toUpperCase(), remember: remember);
    await _enterHostedRoom();
    return hostedRoom?.connected ?? false
        ? 'Connected to the room.'
        : 'Walk your character to your door in the lobby to connect.';
  }

  /// A hosted lobby's QR: connect straight to that seat.
  Future<String> claimHostedSeat(String ticket, {bool remember = false}) async {
    if (!cloud.signedIn) throw signInFirst;
    await _pushAccount();
    await cloud.claim(ticket, remember: remember);
    await _enterHostedRoom();
    return 'Connected to the room.';
  }

  Future<void> _enterHostedRoom() async {
    inHostedRoom = true;
    await prefs.setBool('hosted_room', true);
    startPolling();
    await refreshHostedRoom();
  }

  Future<void> refreshHostedRoom() async {
    if (!cloud.signedIn) return;
    try {
      hostedRoom = await cloud.roomStatus();
      sessionError = null;
    } on SignedOut {
      await _forgetAccount();
    } on ApiError catch (e) {
      sessionError = e.message;
    }
    notifyListeners();
  }

  Future<void> leaveHostedRoom() async {
    final room = hostedRoom;
    if (room != null && room.waiting) {
      await cloud.cancelPickup();
    } else {
      await cloud.leaveRoom();
    }
    hostedRoom = null;
    inHostedRoom = false;
    await prefs.remove('hosted_room');
    if (_api == null) _poll?.cancel();
    notifyListeners();
  }

  Future<void> setHostedRemember(bool value) async {
    final code = hostedRoom?.code;
    if (code == null) return;
    await cloud.remember(code, value);
    await refreshHostedRoom();
  }

  Future<void> setHostedMainPlayer(bool value) async {
    final code = hostedRoom?.code;
    if (code == null) return;
    await cloud.mainPlayer(code, value);
    await refreshHostedRoom();
  }

  // ---- Playlist ---------------------------------------------------------

  String newRequestId() {
    final rng = Random.secure();
    return List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _saveTimer?.cancel();
    _api?.close();
    cloud.close();
    super.dispose();
  }
}
