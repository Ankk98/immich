import 'package:cancellation_token_http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart' show PMProgressHandler;
import 'package:immich_mobile/models/backup/backup_candidate.model.dart';
import 'package:immich_mobile/models/backup/success_upload_asset.model.dart';
import 'package:immich_mobile/models/backup/error_upload_asset.model.dart';
import 'package:immich_mobile/models/backup/current_upload_asset.model.dart';
import 'package:immich_mobile/services/backup_asset_uploader.service.dart';

class BackupAssetUploadTask {
  final BackupCandidate candidate;
  final BackupAssetUploader uploader;
  final PMProgressHandler? pmProgressHandler;
  final void Function(SuccessUploadAsset) onSuccess;
  final void Function(ErrorUploadAsset) onError;
  final void Function(CurrentUploadAsset) onCurrentAsset;
  final void Function(int bytes, int totalBytes) onProgress;

  BackupAssetUploadTask({
    required this.candidate,
    required this.uploader,
    required this.onSuccess,
    required this.onError,
    required this.onCurrentAsset,
    required this.onProgress,
    this.pmProgressHandler,
  });

  Future<bool> run(http.CancellationToken cancelToken) async {
    final asset = candidate.asset;

    // Get file size from origin file
    final originFile = await asset.local?.originFile;
    final fileSize = originFile?.lengthSync() ?? 0;

    onCurrentAsset(
      CurrentUploadAsset(
        id: asset.localId!,
        fileCreatedAt: asset.fileCreatedAt,
        fileName: asset.fileName,
        fileType: asset.type.name.toUpperCase(),
        fileSize: fileSize,
        iCloudAsset: false,
      ),
    );

    final result = await uploader.uploadAsset(
      candidate,
      cancelToken,
      pmProgressHandler,
      onProgress,
    );

    if (result.success) {
      if (result.isDuplicate) {
        onSuccess(
          SuccessUploadAsset(
            candidate: candidate,
            remoteAssetId: asset.localId!,
            isDuplicate: true,
          ),
        );
      } else {
        onSuccess(
          SuccessUploadAsset(
            candidate: candidate,
            remoteAssetId: result.remoteId!,
            isDuplicate: false,
          ),
        );
      }
      return true;
    } else {
      onError(
        ErrorUploadAsset(
          asset: asset,
          id: asset.localId!,
          fileCreatedAt: asset.fileCreatedAt,
          fileName: asset.fileName,
          fileType: asset.type.name.toUpperCase(),
          errorMessage: result.error!,
        ),
      );
      return false;
    }
  }
}
