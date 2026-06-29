import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/check_in_record.dart';
import '../services/check_in_sync_service.dart';

/// 全屏查看打卡照片
class CheckInPhotoViewer extends StatelessWidget {
  const CheckInPhotoViewer({
    super.key,
    required this.syncService,
    required this.record,
    this.isMine = false,
    this.onDelete,
  });

  final CheckInSyncService syncService;
  final CheckInRecord record;
  final bool isMine;
  final VoidCallback? onDelete;

  static Future<void> show(
    BuildContext context, {
    required CheckInSyncService syncService,
    required CheckInRecord record,
    bool isMine = false,
    VoidCallback? onDelete,
  }) {
    if (record.photoPath == null || record.photoPath!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该记录没有照片')),
      );
      return Future.value();
    }
    return showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => CheckInPhotoViewer(
        syncService: syncService,
        record: record,
        isMine: isMine,
        onDelete: onDelete,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('yyyy年M月d日 HH:mm').format(record.timestamp);

    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: SafeArea(
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isMine && onDelete != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.white),
                    onPressed: () {
                      Navigator.pop(context);
                      onDelete!.call();
                    },
                  ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            Expanded(
              child: FutureBuilder<File?>(
                future: syncService.loadPhoto(record.photoPath!),
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    );
                  }
                  final file = snapshot.data;
                  if (file == null) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.broken_image_outlined,
                              size: 64,
                              color: Colors.white.withValues(alpha: 0.5)),
                          const SizedBox(height: 12),
                          Text(
                            '照片加载失败',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4,
                    child: Center(
                      child: Image.file(
                        file,
                        fit: BoxFit.contain,
                      ),
                    ),
                  );
                },
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              color: Colors.black.withValues(alpha: 0.6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    dateStr,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    record.userLabel,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 13,
                    ),
                  ),
                  if (record.locationName != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.location_on,
                            size: 14,
                            color: Colors.white.withValues(alpha: 0.7)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            record.locationName!,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
