import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import '../models/google_calendar_user.dart';
import 'app_log_service.dart';

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
  static const String logSource = 'check_in_location';

  /// 可由逻辑测试注入，避免测试真正打开系统设置或调用定位插件。
  static CheckInLocationSettingsLauncher? settingsLauncherForTesting;
  static CheckInLocationLoader? locationLoaderForTesting;

  static Future<CheckInLocationPermissionStatus>
      requestPermissionStatus() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      switch (permission) {
        case LocationPermission.always:
        case LocationPermission.whileInUse:
          return CheckInLocationPermissionStatus.granted;
        case LocationPermission.deniedForever:
          AppLogService.instance.warning(
            '定位权限被永久拒绝',
            source: logSource,
          );
          return CheckInLocationPermissionStatus.deniedForever;
        case LocationPermission.denied:
          AppLogService.instance.warning(
            '定位权限未授予',
            source: logSource,
          );
          return CheckInLocationPermissionStatus.denied;
        case LocationPermission.unableToDetermine:
          AppLogService.instance.warning(
            '无法确定定位权限状态',
            source: logSource,
          );
          return CheckInLocationPermissionStatus.unavailable;
      }
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '检查或请求定位权限时发生异常',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
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
      } catch (error, stackTrace) {
        AppLogService.instance.error(
          '定位加载器发生异常',
          source: logSource,
          error: error,
          stackTrace: stackTrace,
        );
        return const CheckInLocationAccessResult(
          permissionStatus: CheckInLocationPermissionStatus.unavailable,
        );
      }
    }

    final permissionStatus = await requestPermissionStatus();
    if (permissionStatus != CheckInLocationPermissionStatus.granted) {
      return CheckInLocationAccessResult(permissionStatus: permissionStatus);
    }

    // 该状态在部分 Android 设备上表示“定位源可供此应用使用”，不等同于
    // 系统定位总开关。先尝试权限和定位；状态为 false 时走 Android 原生
    // LocationManager 路径兜底，避免被 FusedLocationProvider 的误报拦住。
    var locationServiceEnabled = true;
    try {
      locationServiceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!locationServiceEnabled) {
        AppLogService.instance.warning(
          'Geolocator 未检测到可供应用使用的定位源，仍将尝试获取位置',
          source: logSource,
        );
      }
    } catch (error, stackTrace) {
      locationServiceEnabled = false;
      AppLogService.instance.warning(
        '读取定位源状态失败，仍将尝试获取位置',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
    }
    final useAndroidLocationManager =
        defaultTargetPlatform == TargetPlatform.android &&
            !locationServiceEnabled;

    // 优先用缓存位置（毫秒级），避免每次都等 GPS 冷启动
    Position? lastKnownPosition;
    try {
      lastKnownPosition = await Geolocator.getLastKnownPosition(
        forceAndroidLocationManager: useAndroidLocationManager,
      ).timeout(const Duration(seconds: 3));
    } catch (error, stackTrace) {
      AppLogService.instance.info(
        '读取缓存定位失败，继续请求实时定位',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
    }

    late final Position position;
    late final bool usedLastKnownPosition;
    if (lastKnownPosition != null &&
        DateTime.now().difference(lastKnownPosition.timestamp).inSeconds <=
            30) {
      position = lastKnownPosition;
      usedLastKnownPosition = true;
    } else {
      // 缓存过期或不可用，重新获取
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: useAndroidLocationManager
              ? AndroidSettings(
                  accuracy: LocationAccuracy.medium,
                  timeLimit: Duration(seconds: 8),
                  forceLocationManager: true,
                )
              : const LocationSettings(
                  accuracy: LocationAccuracy.medium,
                  timeLimit: Duration(seconds: 8),
                ),
        );
      } catch (error, stackTrace) {
        AppLogService.instance.error(
          '获取实时定位失败（accuracy=medium，超时限制 8 秒）',
          source: logSource,
          error: error,
          stackTrace: stackTrace,
        );
        return const CheckInLocationAccessResult(
          permissionStatus: CheckInLocationPermissionStatus.unavailable,
        );
      }
      usedLastKnownPosition = false;
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
    } catch (error, stackTrace) {
      AppLogService.instance.warning(
        '逆地理编码失败，位置名称将回退为经纬度',
        source: logSource,
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (locationName == null || locationName.isEmpty) {
      locationName =
          '${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}';
    }

    AppLogService.instance.info(
      '定位获取成功（${usedLastKnownPosition ? '使用缓存位置' : '使用实时定位'}）',
      source: logSource,
    );

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
