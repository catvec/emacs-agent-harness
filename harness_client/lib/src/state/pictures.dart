import 'dart:async';
import 'dart:collection';

import '../acp/acp_client.dart';
import '../models/picture.dart';
import '../services/harness_api.dart';

/// Where the app gets the pictures of the harness's machine from.
///
/// A tool result and a hand-in name the pictures they show by a path on the
/// harness's machine, which a phone cannot open.  The harness gives their
/// bytes instead (`session/image`), for a file the session's transcript
/// shows.  Widgets ask a source, not the harness, so that what they draw can
/// be tried without one, and so that a picture asked for twice is fetched
/// once.
abstract class PictureSource {
  /// Whether the harness gives pictures at all.  An older one does not, and
  /// its pictures are named and not drawn.
  bool get available;

  /// The picture at [path], which session [sessionId]'s transcript shows.
  /// It fails with the harness's words ([AcpException]) when it cannot be
  /// given: the file is gone, it is too large, it is no picture.
  Future<Picture> load(String sessionId, String path);

  /// The picture at [path], when it has been fetched already, else null:
  /// a widget that is built again draws it at once.
  Picture? peek(String sessionId, String path);
}

/// The pictures of the harness this app is connected to, kept while they are
/// looked at: a transcript is built again as it is scrolled, and a picture of
/// several megabytes is not fetched again each time it comes into view.
///
/// What is kept is bounded: the oldest go when more than [limit] bytes are
/// held.  A request that failed is not kept, so that asking again tries
/// again; and all of it goes with the connection ([clear]), since a file of
/// the harness's machine may have changed by the time the app is back.
class HarnessPictures implements PictureSource {
  HarnessPictures(this._api, {this.limit = 64 * 1024 * 1024});

  /// The api of the connection now: a getter, as it is replaced when the app
  /// connects anew, and null while there is none.
  final HarnessApi? Function() _api;

  /// The most bytes of pictures kept.
  final int limit;

  /// Oldest first.  A picture still on its way is here too, with no size.
  final LinkedHashMap<String, Future<Picture>> _kept = LinkedHashMap();
  final Map<String, Picture> _fetched = {};
  int _total = 0;

  @override
  bool get available => _api()?.can('session/image') ?? false;

  /// How many pictures are kept (or on their way).
  int get count => _kept.length;

  /// How many bytes of pictures are kept.
  int get bytes => _total;

  @override
  Picture? peek(String sessionId, String path) => _fetched['$sessionId\n$path'];

  @override
  Future<Picture> load(String sessionId, String path) {
    final key = '$sessionId\n$path';
    final kept = _kept.remove(key);
    if (kept != null) {
      // Asked for again: it is the newest.
      _kept[key] = kept;
      return kept;
    }
    final api = _api();
    if (api == null) {
      return Future<Picture>.error(
        const AcpException(-32003, 'The app is not connected to the harness.'),
      );
    }
    final fetch = api.sessionImage(sessionId, path);
    _kept[key] = fetch;
    unawaited(
      fetch.then(
        (picture) {
          // Forgotten while it came: it is not kept.
          if (!identical(_kept[key], fetch)) return;
          _fetched[key] = picture;
          _total += picture.bytes.length;
          _trim();
        },
        onError: (Object _) {
          if (identical(_kept[key], fetch)) _kept.remove(key);
        },
      ),
    );
    return fetch;
  }

  /// Drop the oldest pictures until what is kept fits [limit], the newest
  /// one always staying.
  void _trim() {
    while (_total > limit && _kept.length > 1) {
      final oldest = _kept.keys.first;
      _kept.remove(oldest);
      _total -= _fetched.remove(oldest)?.bytes.length ?? 0;
    }
  }

  /// Forget every picture.
  void clear() {
    _kept.clear();
    _fetched.clear();
    _total = 0;
  }
}
