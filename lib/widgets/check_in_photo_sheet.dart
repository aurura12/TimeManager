import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/check_in_goal.dart';
import '../services/app_log_service.dart';
import '../services/check_in_location_service.dart';
import '../services/check_in_sync_service.dart';
import '../utils/platform_features.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// 拍照 / 相册打卡底部弹窗
class CheckInPhotoSheet extends StatefulWidget {
  const CheckInPhotoSheet({
    super.key,
    required this.goal,
    required this.syncService,
    this.initialDate,
  });

  final CheckInGoal goal;
  final CheckInSyncService syncService;

  /// 初始打卡日期，为 null 时默认今天；非 null 时作为补打卡的初始日期
  final DateTime? initialDate;

  @override
  State<CheckInPhotoSheet> createState() => _CheckInPhotoSheetState();
}

class _CheckInPhotoSheetState extends State<CheckInPhotoSheet>
    with SingleTickerProviderStateMixin {
  final _picker = ImagePicker();

  File? _photoFile;
  bool _uploading = false;
  bool _locating = true;
  bool _locationFailed = false;
  bool _locationPermanentlyDenied = false;
  CheckInLocationResult? _location;
  late AnimationController _checkAnim;
  String? _error;
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    _checkAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _selectedDate = widget.initialDate ?? DateTime.now();
    _loadLocation();
  }

  /// 是否补卡：初始日期非空则一定是补卡入口，否则看日期是否是今天
  bool get _isBackfill {
    if (widget.initialDate != null) return true;
    final now = DateTime.now();
    final sel = _selectedDate;
    return sel.year != now.year || sel.month != now.month || sel.day != now.day;
  }

  /// 是否允许在这个弹窗里改日期。
  ///
  /// 只有补打卡入口（[CheckInPhotoSheet.initialDate] 非空）才需要改日期；正常打卡
  /// 记的就是「现在」，日期行只作展示，点了也不该能改——否则随手确定一下就会
  /// 把打卡记成别的日期。
  bool get _canPickDate => widget.initialDate != null;

  String get _dateLabel {
    if (_isBackfill) {
      return '${_selectedDate.month}月${_selectedDate.day}日 '
          '${_selectedDate.hour.toString().padLeft(2, '0')}:'
          '${_selectedDate.minute.toString().padLeft(2, '0')}';
    }
    final now = DateTime.now();
    if (_selectedDate.year == now.year &&
        _selectedDate.month == now.month &&
        _selectedDate.day == now.day) {
      return '今天';
    }
    return '${_selectedDate.month}月${_selectedDate.day}日 '
        '${_selectedDate.hour.toString().padLeft(2, '0')}:'
        '${_selectedDate.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _checkAnim.dispose();
    super.dispose();
  }

  Future<void> _loadLocation() async {
    if (!widget.goal.requireLocation) {
      if (!mounted) return;
      setState(() => _locating = false);
      return;
    }

    if (!mounted) return;
    setState(() {
      _locating = true;
      _locationFailed = false;
      _locationPermanentlyDenied = false;
      _error = null;
    });

    CheckInLocationAccessResult access;
    try {
      access = await CheckInLocationService.getCurrentLocationWithStatus();
    } catch (error, stackTrace) {
      AppLogService.instance.error(
        '打卡弹窗获取定位时发生未处理异常',
        source: CheckInLocationService.logSource,
        error: error,
        stackTrace: stackTrace,
      );
      access = const CheckInLocationAccessResult(
        permissionStatus: CheckInLocationPermissionStatus.unavailable,
      );
    }
    if (!mounted) return;
    setState(() {
      _locating = false;
      _location = access.location;
      _locationFailed = !access.isGranted;
      _locationPermanentlyDenied = access.isPermanentlyDenied;
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    if (!mounted || _uploading) return;
    if (source == ImageSource.camera && !supportsCameraCapture) return;
    setState(() => _error = null);
    try {
      final picked = await _picker.pickImage(
        source: source,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 95,
      );
      if (picked == null || !mounted) return;
      setState(() => _photoFile = File(picked.path));
    } catch (e) {
      if (!mounted) return;
      final action = source == ImageSource.camera ? '打开相机' : '打开相册';
      setState(() => _error = '无法$action: $e');
    }
  }

  Future<void> _submit() async {
    if (!mounted) return;
    if (widget.goal.requirePhoto && _photoFile == null) return;
    if (widget.goal.requireLocation && _location == null) {
      setState(() => _error = '需要位置信息才能打卡');
      return;
    }

    setState(() {
      _uploading = true;
      _error = null;
    });

    CheckInSyncResult result;
    try {
      result = await widget.syncService.submitCheckIn(
        goal: widget.goal,
        photoFile: _photoFile,
        location: _location,
        backfillDate: _isBackfill ? _selectedDate : null,
        isBackfill: _isBackfill,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _error = '打卡失败，请稍后重试';
      });
      return;
    }

    if (!mounted) return;

    if (!result.success) {
      setState(() {
        _uploading = false;
        _error = result.error ?? '打卡失败';
      });
      return;
    }

    setState(() => _uploading = false);
    try {
      await _checkAnim.forward();
    } catch (_) {
      // 页面被外部关闭时动画可能被取消；此时不再更新 UI。
    }
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _openLocationSettings() async {
    final opened = await CheckInLocationService.openAppSettings();
    if (!mounted || opened) return;
    setState(() => _error = '无法打开系统设置，请手动开启定位权限');
  }

  String get _locationText {
    if (!widget.goal.requireLocation) return '未启用位置记录';
    if (_locating) return '正在获取位置...';
    if (_locationPermanentlyDenied) return '定位权限已拒绝，请在系统设置中开启';
    if (_locationFailed) return '定位失败，请检查权限';
    return _location?.locationName ?? '未知位置';
  }

  bool get _canSubmit {
    if (_uploading) return false;
    if (widget.goal.requirePhoto && _photoFile == null) return false;
    if (_locating) return false;
    if (widget.goal.requireLocation && _location == null) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.92;

    return Container(
      margin: EdgeInsets.only(bottom: bottom),
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                    borderRadius: AppRadius.gridAll,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppSemanticColors.tint(widget.goal.color,
                            AppSurfaces.of(context).card, 0.2),
                        borderRadius: AppRadius.controlAll,
                      ),
                      child: Icon(widget.goal.icon,
                          color: AppSemanticColors.onTint(
                              widget.goal.color, AppSurfaces.of(context).card,
                              alpha: 0.2),
                          size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.goal.name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            widget.goal.requirePhoto
                                ? supportsCameraCapture
                                    ? '拍照或从相册选择，压缩后上传'
                                    : '从相册选择，压缩后上传'
                                : '照片可选，也可直接打卡',
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed:
                          _uploading ? null : () => Navigator.pop(context),
                      tooltip: '关闭',
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // 日期行：仅补打卡可改，最晚只能选到昨天（今天走正常打卡入口）
                InkWell(
                  borderRadius: AppRadius.controlAll,
                  onTap: (!_canPickDate || _uploading)
                      ? null
                      : () async {
                          final now = DateTime.now();
                          final yesterday = DateTime(now.year, now.month, now.day)
                              .subtract(const Duration(days: 1));
                          // initialDate 必须在 [firstDate, lastDate] 内，否则
                          // showDatePicker 会断言失败，这里兜一下未来日期。
                          final initialDate = _selectedDate.isAfter(yesterday)
                              ? yesterday
                              : _selectedDate;
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: initialDate,
                            firstDate: DateTime(2024),
                            lastDate: yesterday,
                            locale: const Locale('zh'),
                          );
                          if (picked != null && mounted) {
                            setState(() => _selectedDate = DateTime(
                                  picked.year,
                                  picked.month,
                                  picked.day,
                                  _selectedDate.hour,
                                  _selectedDate.minute,
                                ));
                          }
                        },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: AppRadius.controlAll,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.calendar_today,
                            size: 16, color: colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Text(
                          _dateLabel,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        if (_isBackfill) ...[
                          const SizedBox(width: 6),
                          Builder(builder: (context) {
                            // 徽标下面还压着一层 surfaceContainerHighest@50%，
                            // 先合成成不透明底面再算同色淡底上的文字色。
                            final badgeBg = AppSemanticColors.compose(
                              colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.5),
                              AppSurfaces.of(context).card,
                            );
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: AppSemanticColors.tint(
                                    AppSemanticColors.warning, badgeBg, 0.2),
                                borderRadius: AppRadius.gridAll,
                              ),
                              child: Text('补',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: AppSemanticColors.onTint(
                                          AppSemanticColors.warning, badgeBg,
                                          alpha: 0.2))),
                            );
                          }),
                        ],
                        const SizedBox(width: 6),
                        Icon(Icons.arrow_drop_down,
                            size: 18, color: colorScheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: AppRadius.cardAll,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_photoFile != null)
                          // cacheWidth 限制解码尺寸：相机原图约 12MP，
                          // 预览仅需屏幕宽度，避免解码全分辨率导致内存峰值
                          Image.file(_photoFile!,
                              fit: BoxFit.cover, cacheWidth: 1280)
                        else
                          Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.add_photo_alternate_outlined,
                                    size: 48,
                                    color: Colors.white.withValues(alpha: 0.5)),
                                const SizedBox(height: 8),
                                Text(
                                  supportsCameraCapture ? '拍照或从相册选择' : '从相册选择',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.6),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (_uploading)
                          Container(
                            color: Colors.black54,
                            child: const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(
                                      color: Colors.white),
                                  SizedBox(height: 12),
                                  Text('压缩并上传中...',
                                      style: TextStyle(color: Colors.white)),
                                ],
                              ),
                            ),
                          ),
                        Positioned(
                          left: 12,
                          bottom: 12,
                          right: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: AppRadius.controlAll,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _locating
                                      ? Icons.my_location
                                      : _locationFailed
                                          ? Icons.location_off
                                          : Icons.location_on,
                                  size: 16,
                                  color: _locationFailed
                                      ? AppSemanticColors.warning
                                      : AppSemanticColors.brandSurface,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    _locationText,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (_locationFailed &&
                                    widget.goal.requireLocation)
                                  Wrap(
                                    spacing: 2,
                                    children: [
                                      if (_locationPermanentlyDenied)
                                        TextButton(
                                          onPressed: _uploading
                                              ? null
                                              : _openLocationSettings,
                                          child: const Text(
                                            '打开设置',
                                            style:
                                                TextStyle(color: Colors.white),
                                          ),
                                        ),
                                      TextButton(
                                        onPressed:
                                            _uploading ? null : _loadLocation,
                                        child: const Text(
                                          '重试',
                                          style: TextStyle(color: Colors.white),
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: TextStyle(color: colorScheme.error)),
                ],
                const SizedBox(height: 16),
                if (_photoFile == null)
                  Column(
                    children: [
                      if (supportsCameraCapture)
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _uploading
                                    ? null
                                    : () => _pickImage(ImageSource.gallery),
                                icon: const Icon(Icons.photo_library_outlined),
                                label: const Text('相册'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _uploading
                                    ? null
                                    : () => _pickImage(ImageSource.camera),
                                icon: const Icon(Icons.camera_alt),
                                label: const Text('拍照'),
                              ),
                            ),
                          ],
                        )
                      else
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _uploading
                                ? null
                                : () => _pickImage(ImageSource.gallery),
                            icon: const Icon(Icons.photo_library_outlined),
                            label: const Text('相册'),
                          ),
                        ),
                      if (!widget.goal.requirePhoto) ...[
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _canSubmit ? _submit : null,
                            icon: const Icon(Icons.skip_next),
                            label: Text(_uploading ? '打卡中...' : '不拍照，直接打卡'),
                          ),
                        ),
                      ],
                    ],
                  )
                else
                  Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (supportsCameraCapture)
                        TextButton.icon(
                          onPressed: _uploading
                              ? null
                              : () => _pickImage(ImageSource.camera),
                          icon: const Icon(Icons.camera_alt, size: 18),
                          label: const Text('重拍'),
                        ),
                      TextButton.icon(
                        onPressed: _uploading
                            ? null
                            : () => _pickImage(ImageSource.gallery),
                        icon:
                            const Icon(Icons.photo_library_outlined, size: 18),
                        label: const Text('换一张'),
                      ),
                      FilledButton.icon(
                        onPressed: _canSubmit ? _submit : null,
                        icon: const Icon(Icons.cloud_upload),
                        label: Text(_uploading ? '上传中...' : '确认打卡'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
