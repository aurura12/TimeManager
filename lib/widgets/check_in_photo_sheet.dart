import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/check_in_goal.dart';
import '../services/check_in_location_service.dart';
import '../services/check_in_sync_service.dart';

/// 拍照打卡底部弹窗
class CheckInPhotoSheet extends StatefulWidget {
  const CheckInPhotoSheet({
    super.key,
    required this.goal,
    required this.syncService,
  });

  final CheckInGoal goal;
  final CheckInSyncService syncService;

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

  @override
  void initState() {
    super.initState();
    _checkAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _loadLocation();
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

  Future<void> _takePhoto() async {
    setState(() => _error = null);
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 95,
      );
      if (picked == null || !mounted) return;
      setState(() => _photoFile = File(picked.path));
    } catch (e) {
      setState(() => _error = '无法打开相机: $e');
    }
  }

  Future<void> _submit() async {
    if (_photoFile == null) return;
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
      photoFile: _photoFile!,
      location: _location,
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
    if (_uploading || _photoFile == null) return false;
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
                          '拍照后压缩上传至 GitHub',
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
                              Icon(Icons.camera_alt_outlined,
                                  size: 48,
                                  color: Colors.white.withValues(alpha: 0.5)),
                              const SizedBox(height: 8),
                              Text(
                                '点击下方按钮拍照',
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
              Row(
                children: [
                  if (_photoFile != null && !_uploading)
                    TextButton.icon(
                      onPressed: _takePhoto,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重拍'),
                    ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _photoFile == null
                        ? _takePhoto
                        : (_canSubmit ? _submit : null),
                    icon: Icon(
                        _photoFile == null ? Icons.camera_alt : Icons.cloud_upload),
                    label: Text(
                      _photoFile == null
                          ? '拍照'
                          : (_uploading ? '上传中...' : '确认打卡'),
                    ),
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
