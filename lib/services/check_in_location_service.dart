import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import '../models/google_calendar_user.dart';

class CheckInLocationResult {
  final double latitude;
  final double longitude;
  final String? locationName;

  const CheckInLocationResult({
    required this.latitude,
    required this.longitude,
    this.locationName,
  });
}

class CheckInLocationService {
  static Future<bool> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  static Future<CheckInLocationResult?> getCurrentLocation() async {
    final ok = await ensurePermission();
    if (!ok) return null;

    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 12),
      ),
    );

    String? locationName;
    try {
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      ).timeout(const Duration(seconds: 3));
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        locationName = [
          p.administrativeArea,
          p.locality,
          p.subLocality,
          p.name,
        ].where((e) => e != null && e.trim().isNotEmpty).join('');
      }
    } catch (_) {}

    locationName ??=
        '${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}';

    return CheckInLocationResult(
      latitude: position.latitude,
      longitude: position.longitude,
      locationName: locationName,
    );
  }
}

/// 当前打卡用户身份（来自 Google 日历登录）
class CheckInUserContext {
  final GoogleCalendarUser user;

  const CheckInUserContext({required this.user});

  String get id => user.id;
  String get email => user.email;
  String? get displayName => user.displayName;
}
