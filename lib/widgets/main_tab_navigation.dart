import 'package:flutter/material.dart';

import '../models/main_tab_id.dart';

extension MainTabNavigation on MainTabId {
  IconData get icon => switch (this) {
        MainTabId.record => Icons.home_outlined,
        MainTabId.diary => Icons.menu_book_outlined,
        MainTabId.travel => Icons.card_travel_outlined,
        MainTabId.checkIn => Icons.check_circle_outline,
        MainTabId.target => Icons.flag_outlined,
        MainTabId.profile => Icons.person_outline,
      };

  IconData get selectedIcon => switch (this) {
        MainTabId.record => Icons.home,
        MainTabId.diary => Icons.menu_book,
        MainTabId.travel => Icons.card_travel,
        MainTabId.checkIn => Icons.check_circle,
        MainTabId.target => Icons.flag,
        MainTabId.profile => Icons.person,
      };
}
