import 'buddy_window.dart';

/// The web has no native window; the persistent in-app card is the buddy.
BuddyWindowService createBuddyWindowService() =>
    UnsupportedBuddyWindowService();
