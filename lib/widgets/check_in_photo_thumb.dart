import 'dart:io';

import 'package:flutter/material.dart';

import '../services/check_in_sync_service.dart';

/// 从 GitHub 加载并显示打卡照片
class CheckInPhotoThumb extends StatelessWidget {
  const CheckInPhotoThumb({
    super.key,
    required this.syncService,
    required this.photoPath,
    this.width = 56,
    this.height = 56,
    this.borderRadius = 10,
  });

  final CheckInSyncService syncService;
  final String? photoPath;
  final double width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    if (photoPath == null || photoPath!.isEmpty) {
      return _placeholder(context);
    }

    return FutureBuilder<File?>(
      future: syncService.loadPhoto(photoPath!),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _placeholder(context, loading: true);
        }
        final file = snapshot.data;
        if (file == null) return _placeholder(context);

        return ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Image.file(
            file,
            width: width,
            height: height,
            fit: BoxFit.cover,
          ),
        );
      },
    );
  }

  Widget _placeholder(BuildContext context, {bool loading = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: loading
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.photo_camera, color: colorScheme.onSurfaceVariant),
    );
  }
}
