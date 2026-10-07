import 'dart:convert';
import 'dart:math';

import 'avatar.dart';

/// One saved face. Players keep several, so trying something new never costs
/// them the last one.
class Artwork {
  final String id;
  String name;
  Pixels data;
  Artwork({required this.id, required this.name, required this.data});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'face': encodeAvatar(data)};

  static Artwork? fromJson(Object? j) {
    if (j is! Map) return null;
    final data = decodeAvatar(j['face'] as String?);
    final id = j['id'], name = j['name'];
    if (data == null || id is! String || name is! String) return null;
    return Artwork(id: id, name: name, data: data);
  }
}

String newArtworkId([Random? random]) {
  final rng = random ?? Random();
  return 'art_${DateTime.now().millisecondsSinceEpoch}_${rng.nextInt(1 << 30).toRadixString(36)}';
}

class BackupError implements Exception {
  final String message;
  const BackupError(this.message);
  @override
  String toString() => message;
}

/// Everything in a backup: the faces plus the name and skin they go with.
class Backup {
  final String username;
  final String skinColor;
  final String? activeArtworkId;
  final List<Artwork> artworks;
  const Backup(
      {required this.username,
      required this.skinColor,
      required this.activeArtworkId,
      required this.artworks});
}

final _hex = RegExp(r'^#[0-9a-fA-F]{6}$');

/// The phone studio's compact backup (version 2): one shared palette, and
/// each face as `[length, paletteIndex]` runs where index 0 is transparent.
/// Backups move freely between this app and the browser studio.
String encodeBackup(Backup backup) {
  final palette = <String>[];
  final indexes = <String, int>{};
  final artworks = [
    for (final art in backup.artworks)
      {
        'id': art.id,
        'name': art.name,
        'runs': () {
          final runs = <int>[];
          for (final pixel in art.data) {
            var index = 0;
            if (pixel != null) {
              final color = pixel.toLowerCase();
              index = indexes.putIfAbsent(color, () {
                palette.add(color);
                return palette.length;
              });
            }
            if (runs.isNotEmpty && runs.last == index) {
              runs[runs.length - 2]++;
            } else {
              runs.addAll([1, index]);
            }
          }
          return runs;
        }(),
      }
  ];
  return jsonEncode({
    'format': 'gamenight-character-backup',
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'gridSize': gridSize,
    'username': backup.username,
    'skinColor': backup.skinColor,
    'activeArtworkId': backup.activeArtworkId,
    'version': 2,
    'palette': palette,
    'artworks': artworks,
  });
}

/// Reads a backup, checking it the way the browser studio does. Nothing is
/// returned unless every face in it is complete.
Backup decodeBackup(String text) {
  final Object? value;
  try {
    value = jsonDecode(text.trim());
  } on FormatException {
    throw const BackupError('This is not a GameNight backup. Nothing was imported.');
  }
  const cells = gridSize * gridSize;
  if (value is! Map ||
      value['format'] != 'gamenight-character-backup' ||
      value['version'] != 2 ||
      value['gridSize'] != gridSize ||
      value['palette'] is! List ||
      value['artworks'] is! List ||
      (value['artworks'] as List).isEmpty ||
      (value['artworks'] as List).length > 200 ||
      value['username'] is! String ||
      (value['username'] as String).length > 100 ||
      value['skinColor'] is! String ||
      !_hex.hasMatch(value['skinColor'] as String)) {
    throw const BackupError('Please import a current GameNight backup.');
  }
  final palette = value['palette'] as List;
  if (palette.length > 200 * cells || !palette.every((c) => c is String && _hex.hasMatch(c))) {
    throw const BackupError('Please import a current GameNight backup.');
  }
  final ids = <String>{};
  final artworks = <Artwork>[];
  for (final art in value['artworks'] as List) {
    if (art is! Map ||
        art['id'] is! String ||
        (art['id'] as String).length > 200 ||
        ids.contains(art['id']) ||
        art['name'] is! String ||
        (art['name'] as String).length > 200 ||
        art['runs'] is! List) {
      throw const BackupError('Invalid face. Nothing was imported.');
    }
    final runs = art['runs'] as List;
    if (runs.isEmpty || runs.length.isOdd || runs.length > cells * 2) {
      throw const BackupError('Invalid face. Nothing was imported.');
    }
    ids.add(art['id'] as String);
    final data = <String?>[];
    for (var i = 0; i < runs.length; i += 2) {
      final length = runs[i], index = runs[i + 1];
      if (length is! int ||
          length < 1 ||
          data.length + length > cells ||
          index is! int ||
          index < 0 ||
          index > palette.length) {
        throw const BackupError('Invalid pixel runs. Nothing was imported.');
      }
      final pixel = index == 0 ? null : palette[index - 1] as String;
      for (var j = 0; j < length; j++) {
        data.add(pixel);
      }
    }
    if (data.length != cells) throw const BackupError('Incomplete face. Nothing was imported.');
    artworks.add(Artwork(id: art['id'] as String, name: art['name'] as String, data: data));
  }
  return Backup(
    username: value['username'] as String,
    skinColor: value['skinColor'] as String,
    activeArtworkId: value['activeArtworkId'] is String ? value['activeArtworkId'] as String : null,
    artworks: artworks,
  );
}
