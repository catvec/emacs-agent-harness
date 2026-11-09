import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:harness_client/src/desktop/buddy_window.dart';

/// Stands in for a native buddy window in a widget test: it records what the
/// app asked for and can fail like a compositor that will not make a window.
class FakeBuddyWindowService implements BuddyWindowService {
  FakeBuddyWindowService({bool available = true, this.failOnShow = false})
    : _available = ValueNotifier<bool>(available);

  final ValueNotifier<bool> _available;
  final ValueNotifier<bool> _activated = ValueNotifier<bool>(false);

  /// The next [show] reports a failure, as a platform without a usable
  /// window does.
  bool failOnShow;

  final List<BuddyWindowRequest> requests = <BuddyWindowRequest>[];
  final List<Size> contentSizes = <Size>[];
  int showCalls = 0;
  int hideCalls = 0;
  int destroyCalls = 0;
  int presentCalls = 0;
  int wraps = 0;
  bool disposed = false;

  BuddyWindowRequest? get lastRequest =>
      requests.isEmpty ? null : requests.last;

  @override
  ValueListenable<bool> get available => _available;

  @override
  bool get isActivated => _activated.value;

  @override
  ValueListenable<bool> get activated => _activated;

  @override
  void reportActivated(bool active) => _activated.value = active;

  @override
  Widget wrap(Widget child) {
    wraps++;
    return child;
  }

  @override
  void show(BuildContext context, BuddyWindowRequest request) {
    showCalls++;
    if (failOnShow) {
      failOnShow = false;
      if (_available.value) _available.value = false;
      return;
    }
    requests.add(request);
  }

  @override
  void hide() => hideCalls++;

  @override
  void reportContentSize(Size size) => contentSizes.add(size);

  @override
  void destroy() => destroyCalls++;

  @override
  void presentMainWindow() => presentCalls++;

  @override
  void dispose() {
    disposed = true;
    _available.dispose();
    _activated.dispose();
  }
}
