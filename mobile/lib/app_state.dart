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

import 'api.dart';
import 'avatar.dart';
import 'faces.dart';
import 'link.dart';

enum SyncState { idle, saving, savedLocally, synced, joined, warning }

class AppState extends ChangeNotifier {
  final SharedPreferences prefs;
  final GameNightApi Function(Uri base) apiFactory;

  AppState(this.prefs, {GameNightApi Function(Uri base)? apiFactory})
      : apiFactory = apiFactory ?? ((base) => GameNightApi(base)) {
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
      final art = Artwork(id: newArtworkId(), name: 'Sketch ${artworks.length + 1}', data: List.of(face));
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
        id: newArtworkId(), name: name ?? 'Sketch ${artworks.length + 1}', data: data ?? randomFace());
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
      var same = artworks
          .where((a) => a.name == incoming.name && encodeAvatar(a.data) == key)
          .firstOrNull;
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

  Profile get profile => Profile(
      id: profileId, username: name, skinColor: skinColor, avatar: encodeAvatar(face));

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
    final api = _api;
    if (api == null) {
      _status(SyncState.savedLocally, 'Saved on your phone');
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
      final result = await api.join(profileId,
          claim: target, seat: claimSeat, linkRevision: linkRevision);
      switch (result.status) {
        case 'unlinked':
          _clearClaim();
          _status(SyncState.savedLocally,
              'Controller unlinked. Your character is kept on this phone.');
          return;
        case 'no_such_seat':
          _status(SyncState.warning, result.message ?? 'Nobody is on that seat any more.');
          return;
        case 'already_signed_in':
          claim = result.playerId;
          claimSeat = null;
          _bind(result.playerId);
          linkRevision = 0;
          _status(SyncState.warning,
              'Already connected. Your edits update your existing character.');
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
      throw const LinkError(
          'This QR is for an online GameNight room. Open it in your browser instead.');
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
    unawaited(refreshSession());
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => refreshSession());
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
    super.dispose();
  }
}
