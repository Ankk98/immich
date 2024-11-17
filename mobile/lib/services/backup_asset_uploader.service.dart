import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:cancellation_token_http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart' show PMProgressHandler;
import 'package:logging/logging.dart';
import 'package:immich_mobile/models/backup/backup_candidate.model.dart';
import 'package:immich_mobile/entities/asset.entity.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/services/api.service.dart';

class MultipartRequest extends http.MultipartRequest {
  /// Creates a new [MultipartRequest].
  MultipartRequest(
    super.method,
    super.url, {
    required this.onProgress,
  });

  final void Function(int bytes, int totalBytes) onProgress;

  /// Freezes all mutable fields and returns a
  /// single-subscription [http.ByteStream]
  /// that will emit the request body.
  @override
  http.ByteStream finalize() {
    final byteStream = super.finalize();

    final total = contentLength;
    var bytes = 0;

    final t = StreamTransformer.fromHandlers(
      handleData: (List<int> data, EventSink<List<int>> sink) {
        bytes += data.length;
        onProgress.call(bytes, total);
        sink.add(data);
      },
    );
    final stream = byteStream.transform(t);
    return http.ByteStream(stream);
  }
}

class BackupAssetUploader {
  final Logger _log = Logger('BackupAssetUploader');
  final http.Client httpClient = http.Client();

  BackupAssetUploader();

  Future<UploadResult> uploadAsset(
    BackupCandidate candidate,
    http.CancellationToken cancelToken,
    PMProgressHandler? pmProgressHandler,
    void Function(int bytes, int totalBytes) onProgress,
  ) async {
    File? file;
    File? livePhotoFile;
    final asset = candidate.asset;

    try {
      final isAvailableLocally =
          await asset.local!.isLocallyAvailable(isOrigin: true);

      file = await _getMainFile(asset, isAvailableLocally, pmProgressHandler);
      if (asset.local!.isLivePhoto) {
        livePhotoFile = await _getLivePhotoFile(
          asset,
          isAvailableLocally,
          pmProgressHandler,
        );
      }

      if (file == null) {
        return UploadResult.failure("Failed to get file");
      }

      String? originalFileName = asset.fileName;
      final deviceId = Store.get(StoreKey.deviceId);
      final baseRequest = _createBaseRequest(
        file,
        originalFileName,
        asset,
        deviceId,
        onProgress,
      );

      String? livePhotoVideoId;
      if (asset.local!.isLivePhoto && livePhotoFile != null) {
        livePhotoVideoId = await _uploadLivePhotoVideo(
          originalFileName,
          livePhotoFile,
          baseRequest,
          cancelToken,
        );
      }

      if (livePhotoVideoId != null) {
        baseRequest.fields['livePhotoVideoId'] = livePhotoVideoId;
      }

      final response =
          await httpClient.send(baseRequest, cancellationToken: cancelToken);
      final responseBody = await response.stream.bytesToString();

      return _handleResponse(response.statusCode, responseBody);
    } catch (error) {
      _log.severe("Upload failed", error);
      return UploadResult.failure(error.toString());
    } finally {
      if (Platform.isIOS) {
        await file?.delete();
        await livePhotoFile?.delete();
      }
    }
  }

  Future<File?> _getMainFile(
    Asset asset,
    bool isAvailableLocally,
    PMProgressHandler? pmProgressHandler,
  ) async {
    if (!isAvailableLocally && Platform.isIOS) {
      return await asset.local!.loadFile(progressHandler: pmProgressHandler);
    } else {
      return asset.type == AssetType.video
          ? await asset.local!.originFile
          : await asset.local!.originFile.timeout(const Duration(seconds: 5));
    }
  }

  Future<File?> _getLivePhotoFile(
    Asset asset,
    bool isAvailableLocally,
    PMProgressHandler? pmProgressHandler,
  ) async {
    if (!isAvailableLocally && Platform.isIOS) {
      return await asset.local!
          .loadFile(withSubtype: true, progressHandler: pmProgressHandler);
    } else {
      return await asset.local!.originFileWithSubtype
          .timeout(const Duration(seconds: 5));
    }
  }

  http.MultipartRequest _createBaseRequest(
    File file,
    String originalFileName,
    Asset asset,
    String deviceId,
    void Function(int bytes, int totalBytes) onProgress,
  ) {
    final fileStream = file.openRead();
    final assetRawUploadData = http.MultipartFile(
      "assetData",
      fileStream,
      file.lengthSync(),
      filename: originalFileName,
    );

    final baseRequest = MultipartRequest(
      'POST',
      Uri.parse('${Store.get(StoreKey.serverEndpoint)}/assets'),
      onProgress: onProgress,
    );

    baseRequest.headers.addAll(ApiService.getRequestHeaders());
    baseRequest.headers["Transfer-Encoding"] = "chunked";
    baseRequest.fields['deviceAssetId'] = asset.localId!;
    baseRequest.fields['deviceId'] = deviceId;
    baseRequest.fields['fileCreatedAt'] =
        asset.fileCreatedAt.toUtc().toIso8601String();
    baseRequest.fields['fileModifiedAt'] =
        asset.fileModifiedAt.toUtc().toIso8601String();
    baseRequest.fields['isFavorite'] = asset.isFavorite.toString();
    baseRequest.fields['duration'] = asset.duration.toString();
    baseRequest.files.add(assetRawUploadData);

    return baseRequest;
  }

  Future<String?> _uploadLivePhotoVideo(
    String originalFileName,
    File livePhotoVideoFile,
    http.MultipartRequest baseRequest,
    http.CancellationToken cancelToken,
  ) async {
    final livePhotoTitle =
        p.setExtension(originalFileName, p.extension(livePhotoVideoFile.path));
    final fileStream = livePhotoVideoFile.openRead();
    final livePhotoRawUploadData = http.MultipartFile(
      "assetData",
      fileStream,
      livePhotoVideoFile.lengthSync(),
      filename: livePhotoTitle,
    );

    final livePhotoReq = MultipartRequest(
      baseRequest.method,
      baseRequest.url,
      onProgress: (baseRequest as MultipartRequest).onProgress,
    )
      ..headers.addAll(baseRequest.headers)
      ..fields.addAll(baseRequest.fields);

    livePhotoReq.files.add(livePhotoRawUploadData);

    final response =
        await httpClient.send(livePhotoReq, cancellationToken: cancelToken);
    final responseBody = await response.stream.bytesToString();

    if (![200, 201].contains(response.statusCode)) {
      _log.warning(
        "Error(${response.statusCode}) uploading livePhoto for assetId | $livePhotoTitle | $responseBody",
      );
      return null;
    }

    return jsonDecode(responseBody)['id'];
  }

  UploadResult _handleResponse(int statusCode, String responseBody) {
    if (statusCode == 200) {
      return UploadResult.duplicate();
    } else if (statusCode == 201) {
      return UploadResult.success(jsonDecode(responseBody)['id']);
    } else {
      return UploadResult.failure("Error($statusCode): $responseBody");
    }
  }
}

class UploadResult {
  final bool success;
  final String? remoteId;
  final bool isDuplicate;
  final String? error;

  const UploadResult.success(this.remoteId)
      : success = true,
        isDuplicate = false,
        error = null;
  const UploadResult.duplicate()
      : success = true,
        isDuplicate = true,
        remoteId = null,
        error = null;
  const UploadResult.failure(this.error)
      : success = false,
        isDuplicate = false,
        remoteId = null;
}
