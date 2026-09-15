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

enum CheckInLocationPermissionStatus {
  granted,
  serviceDisabled,
  denied,
  deniedForever,
  unavailable,
}

class CheckInLocationAccessResult {
  final CheckInLocationPermissionStatus permissionStatus;
  final CheckInLocationResult? location;

  const CheckInLocationAccessResult({
    required this.permissionStatus,
    this.location,
  });

  bool get isGranted =>
      permissionStatus == CheckInLocationPermissionStatus.granted &&
      location != null;

  bool get isPermanentlyDenied =>
      permissionStatus == CheckInLocationPermissionStatus.deniedForever;
}

typedef CheckInLocationSettingsLauncher = Future<bool> Function();
typedef CheckInLocationLoader = Future<CheckInLocationAccessResult> Function();

class CheckInLocationService {
  /// 可由逻辑测试注入，避免测试真正打开系统设置或调用定位插件。
  static CheckInLocationSettingsLauncher? settingsLauncherForTesting;
  static CheckInLocationLoader? locationLoaderForTesting;

  static Future<CheckInLocationPermissionStatus>
      requestPermissionStatus() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return CheckInLocationPermissionStatus.serviceDisabled;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      switch (permission) {
        case LocationPermission.always:
        case LocationPermission.whileInUse:
          return CheckInLocationPermissionStatus.granted;
        case LocationPermission.deniedForever:
          return CheckInLocationPermissionStatus.deniedForever;
        case LocationPermission.denied:
          return CheckInLocationPermissionStatus.denied;
        case LocationPermission.unableToDetermine:
          return CheckInLocationPermissionStatus.unavailable;
      }
    } catch (_) {
      return CheckInLocationPermissionStatus.unavailable;
    }
  }

  static Future<bool> ensurePermission() async {
    return await requestPermissionStatus() ==
        CheckInLocationPermissionStatus.granted;
  }

  static Future<CheckInLocationAccessResult>
      getCurrentLocationWithStatus() async {
    final injectedLoader = locationLoaderForTesting;
    if (injectedLoader != null) {
      try {
        return await injectedLoader();
      } catch (_) {
        return const CheckInLocationAccessResult(
          permissionStatus: CheckInLocationPermissionStatus.unavailable,
        );
      }
    }

    final permissionStatus = await requestPermissionStatus();
    if (permissionStatus != CheckInLocationPermissionStatus.granted) {
      return CheckInLocationAccessResult(permissionStatus: permissionStatus);
    }

    // 优先用缓存位置（毫秒级），避免每次都等 GPS 冷启动
    Position? position;
    try {
      position = await Geolocator.getLastKnownPosition()
          .timeout(const Duration(seconds: 3));
    } catch (_) {}

    if (position == null ||
        DateTime.now().difference(position.timestamp).inSeconds > 30) {
      // 缓存过期或不可用，重新获取
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 8),
          ),
        );
      } catch (_) {
        return const CheckInLocationAccessResult(
          permissionStatus: CheckInLocationPermissionStatus.unavailable,
        );
      }
    }

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

    return CheckInLocationAccessResult(
      permissionStatus: CheckInLocationPermissionStatus.granted,
      location: CheckInLocationResult(
        latitude: position.latitude,
        longitude: position.longitude,
        locationName: locationName,
      ),
    );
  }

  static Future<CheckInLocationResult?> getCurrentLocation() async {
    final access = await getCurrentLocationWithStatus();
    return access.location;
  }

  static Future<bool> openAppSettings() async {
    final launcher = settingsLauncherForTesting ?? Geolocator.openAppSettings;
    try {
      return await launcher();
    } catch (_) {
      return false;
    }
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
