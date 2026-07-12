import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/check_in_goal.dart';
import '../services/check_in_location_service.dart';
import '../services/check_in_sync_service.dart';

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
    return sel.year != now.year ||
        sel.month != now.month ||
        sel.day != now.day;
  }

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
      setState(() => _locating = false);
      return;
    }
    final loc = await CheckInLocationService.getCurrentLocation();
    if (!mounted) return;
    setState(() {
      _locating = false;
      _location = loc;
      _locationFailed = loc == null;
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_uploading) return;
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
      final action = source == ImageSource.camera ? '打开相机' : '打开相册';
      setState(() => _error = '无法$action: $e');
    }
  }

  Future<void> _submit() async {
    if (widget.goal.requirePhoto && _photoFile == null) return;
    if (widget.goal.requireLocation && _location == null) {
      setState(() => _error = '需要位置信息才能打卡');
      return;
    }

    setState(() {
      _uploading = true;
      _error = null;
    });

    final result = await widget.syncService.submitCheckIn(
      goal: widget.goal,
      photoFile: _photoFile,
      location: _location,
      backfillDate: _isBackfill ? _selectedDate : null,
      isBackfill: _isBackfill,
    );

    if (!mounted) return;

    if (!result.success) {
      setState(() {
        _uploading = false;
        _error = result.error ?? '打卡失败';
      });
      return;
    }

    setState(() => _uploading = false);
    await _checkAnim.forward();
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  String get _locationText {
    if (!widget.goal.requireLocation) return '未启用位置记录';
    if (_locating) return '正在获取位置...';
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

    return Container(
      margin: EdgeInsets.only(bottom: bottom),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: widget.goal.color.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(widget.goal.icon,
                        color: widget.goal.color, size: 20),
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
                              ? '拍照或从相册选择，压缩后上传'
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
                    onPressed: _uploading ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 日期选择行（补打卡时显示橙色标记）
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: _uploading
                    ? null
                    : () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _selectedDate,
                          firstDate: DateTime(2024),
                          lastDate: DateTime.now(),
                          locale: const Locale('zh'),
                        );
                        if (picked != null && mounted) {
                          setState(() => _selectedDate = picked);
                        }
                      },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
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
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('补',
                              style: TextStyle(
                                  fontSize: 10, color: Colors.orange)),
                        ),
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
                    borderRadius: BorderRadius.circular(16),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_photoFile != null)
                        Image.file(_photoFile!, fit: BoxFit.cover)
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
                                '拍照或从相册选择',
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
                                CircularProgressIndicator(color: Colors.white),
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
                            borderRadius: BorderRadius.circular(10),
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
                                    ? Colors.orange
                                    : const Color(0xFF96B462),
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
                              if (_locationFailed && widget.goal.requireLocation)
                                TextButton(
                                  onPressed: _loadLocation,
                                  child: const Text('重试',
                                      style: TextStyle(color: Colors.white)),
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
                    ),
                    if (!widget.goal.requirePhoto) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _canSubmit ? _submit : null,
                          icon: const Icon(Icons.skip_next),
                          label: Text(
                              _uploading ? '打卡中...' : '不拍照，直接打卡'),
                        ),
                      ),
                    ],
                  ],
                )
              else
                Row(
                  children: [
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
                      icon: const Icon(Icons.photo_library_outlined, size: 18),
                      label: const Text('换一张'),
                    ),
                    const Spacer(),
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
    );
  }
}
