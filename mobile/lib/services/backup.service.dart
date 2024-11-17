import 'dart:async';
import 'dart:io';

import 'package:cancellation_token_http/http.dart' as http;
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/entities/album.entity.dart';
import 'package:immich_mobile/entities/asset.entity.dart';
import 'package:immich_mobile/entities/backup_album.entity.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/interfaces/album_media.interface.dart';
import 'package:immich_mobile/interfaces/asset.interface.dart';
import 'package:immich_mobile/interfaces/asset_media.interface.dart';
import 'package:immich_mobile/interfaces/file_media.interface.dart';
import 'package:immich_mobile/models/backup/backup_candidate.model.dart';
import 'package:immich_mobile/models/backup/current_upload_asset.model.dart';
import 'package:immich_mobile/models/backup/error_upload_asset.model.dart';
import 'package:immich_mobile/models/backup/success_upload_asset.model.dart';
import 'package:immich_mobile/models/backup/backup_asset_upload_task.model.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/repositories/album_media.repository.dart';
import 'package:immich_mobile/repositories/asset.repository.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:immich_mobile/services/album.service.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:permission_handler/permission_handler.dart' as pm;
import 'package:photo_manager/photo_manager.dart' show PMProgressHandler;
import 'package:immich_mobile/services/backup_asset_uploader.service.dart';

final backupServiceProvider = Provider(
  (ref) => BackupService(
    ref.watch(apiServiceProvider),
    ref.watch(appSettingsServiceProvider),
    ref.watch(albumServiceProvider),
    ref.watch(albumMediaRepositoryProvider),
    ref.watch(fileMediaRepositoryProvider),
    ref.watch(assetRepositoryProvider),
    ref.watch(assetMediaRepositoryProvider),
  ),
);

class BackupService {
  final httpClient = http.Client();
  final ApiService _apiService;
  final AppSettingsService _appSettingsService;
  final AlbumService _albumService;
  final Logger _log = Logger("BackupService");
  final IAlbumMediaRepository _albumMediaRepository;
  final IFileMediaRepository _fileMediaRepository;
  final IAssetRepository _assetRepository;
  final IAssetMediaRepository _assetMediaRepository;
  static const int maxConcurrentUploads = 4;
  final BackupAssetUploader _uploader;

  BackupService(
    this._apiService,
    this._appSettingsService,
    this._albumService,
    this._albumMediaRepository,
    this._fileMediaRepository,
    this._assetRepository,
    this._assetMediaRepository,
  ) : _uploader = BackupAssetUploader();

  Future<List<String>?> getDeviceBackupAsset() async {
    final String deviceId = Store.get(StoreKey.deviceId);

    try {
      return await _apiService.assetsApi.getAllUserAssetsByDeviceId(deviceId);
    } catch (e) {
      debugPrint('Error [getDeviceBackupAsset] ${e.toString()}');
      return null;
    }
  }

  Future<void> _saveDuplicatedAssetIds(List<String> deviceAssetIds) =>
      _assetRepository.transaction(
        () => _assetRepository.upsertDuplicatedAssets(deviceAssetIds),
      );

  /// Get duplicated asset id from database
  Future<Set<String>> getDuplicatedAssetIds() async {
    final duplicates = await _assetRepository.getAllDuplicatedAssetIds();
    return duplicates.toSet();
  }

  /// Returns all assets newer than the last successful backup per album
  /// if `useTimeFilter` is set to true, all assets will be returned
  Future<Set<BackupCandidate>> buildUploadCandidates(
    List<BackupAlbum> selectedBackupAlbums,
    List<BackupAlbum> excludedBackupAlbums, {
    bool useTimeFilter = true,
  }) async {
    final now = DateTime.now();

    final Set<BackupCandidate> toAdd = await _fetchAssetsAndUpdateLastBackup(
      selectedBackupAlbums,
      now,
      useTimeFilter: useTimeFilter,
    );

    if (toAdd.isEmpty) return {};

    final Set<BackupCandidate> toRemove = await _fetchAssetsAndUpdateLastBackup(
      excludedBackupAlbums,
      now,
      useTimeFilter: useTimeFilter,
    );

    return toAdd.difference(toRemove);
  }

  Future<Set<BackupCandidate>> _fetchAssetsAndUpdateLastBackup(
    List<BackupAlbum> backupAlbums,
    DateTime now, {
    bool useTimeFilter = true,
  }) async {
    Set<BackupCandidate> candidates = {};

    for (final BackupAlbum backupAlbum in backupAlbums) {
      final Album localAlbum;
      try {
        localAlbum = await _albumMediaRepository.get(backupAlbum.id);
      } on StateError {
        // the album no longer exists
        continue;
      }

      if (useTimeFilter &&
          localAlbum.modifiedAt.isBefore(backupAlbum.lastBackup)) {
        continue;
      }
      final List<Asset> assets;
      try {
        assets = await _albumMediaRepository.getAssets(
          backupAlbum.id,
          modifiedFrom: useTimeFilter
              ?
              // subtract 2 seconds to prevent missing assets due to rounding issues
              backupAlbum.lastBackup.subtract(const Duration(seconds: 2))
              : null,
          modifiedUntil: useTimeFilter ? now : null,
        );
      } on StateError {
        // either there are no assets matching the filter criteria OR the album no longer exists
        continue;
      }

      // Add album's name to the asset info
      for (final asset in assets) {
        List<String> albumNames = [localAlbum.name];

        final existingAsset = candidates.firstWhereOrNull(
          (candidate) => candidate.asset.localId == asset.localId,
        );

        if (existingAsset != null) {
          albumNames.addAll(existingAsset.albumNames);
          candidates.remove(existingAsset);
        }

        candidates.add(BackupCandidate(asset: asset, albumNames: albumNames));
      }

      backupAlbum.lastBackup = now;
    }

    return candidates;
  }

  /// Returns a new list of assets not yet uploaded
  Future<Set<BackupCandidate>> removeAlreadyUploadedAssets(
    Set<BackupCandidate> candidates,
  ) async {
    if (candidates.isEmpty) {
      return candidates;
    }

    final Set<String> duplicatedAssetIds = await getDuplicatedAssetIds();
    candidates.removeWhere(
      (candidate) => duplicatedAssetIds.contains(candidate.asset.localId),
    );

    if (candidates.isEmpty) {
      return candidates;
    }

    final Set<String> existing = {};
    try {
      final String deviceId = Store.get(StoreKey.deviceId);
      final CheckExistingAssetsResponseDto? duplicates =
          await _apiService.assetsApi.checkExistingAssets(
        CheckExistingAssetsDto(
          deviceAssetIds: candidates.map((c) => c.asset.localId!).toList(),
          deviceId: deviceId,
        ),
      );
      if (duplicates != null) {
        existing.addAll(duplicates.existingIds);
      }
    } on ApiException {
      // workaround for older server versions or when checking for too many assets at once
      final List<String>? allAssetsInDatabase = await getDeviceBackupAsset();
      if (allAssetsInDatabase != null) {
        existing.addAll(allAssetsInDatabase);
      }
    }

    if (existing.isNotEmpty) {
      candidates.removeWhere((c) => existing.contains(c.asset.localId));
    }

    return candidates;
  }

  Future<bool> _checkPermissions() async {
    if (Platform.isAndroid &&
        !(await pm.Permission.accessMediaLocation.status).isGranted) {
      // double check that permission is granted here, to guard against
      // uploading corrupt assets without EXIF information
      _log.warning("Media location permission is not granted. "
          "Cannot access original assets for backup.");

      return false;
    }

    // DON'T KNOW WHY BUT THIS HELPS BACKGROUND BACKUP TO WORK ON IOS
    if (Platform.isIOS) {
      await _fileMediaRepository.requestExtendedPermissions();
    }

    return true;
  }

  /// Upload images before video assets for background tasks
  /// these are further sorted by using their creation date
  List<BackupCandidate> _sortPhotosFirst(List<BackupCandidate> candidates) {
    return candidates.sorted(
      (a, b) {
        final cmp = a.asset.type.index - b.asset.type.index;
        if (cmp != 0) return cmp;
        return a.asset.fileCreatedAt.compareTo(b.asset.fileCreatedAt);
      },
    );
  }

  Future<bool> backupAsset(
    Iterable<BackupCandidate> assets,
    http.CancellationToken cancelToken, {
    bool isBackground = false,
    PMProgressHandler? pmProgressHandler,
    required void Function(SuccessUploadAsset result) onSuccess,
    required void Function(int bytes, int totalBytes) onProgress,
    required void Function(CurrentUploadAsset asset) onCurrentAsset,
    required void Function(ErrorUploadAsset error) onError,
  }) async {
    bool anyErrors = false;
    final Set<String> duplicatedAssetIds = {};

    final hasPermission = await _checkPermissions();
    if (!hasPermission) {
      return false;
    }

    List<BackupCandidate> candidates = assets.toList();
    if (isBackground) {
      candidates = _sortPhotosFirst(candidates);
    }

    // Process in chunks of maxConcurrentUploads
    for (var i = 0; i < candidates.length; i += maxConcurrentUploads) {
      final chunk = candidates.skip(i).take(maxConcurrentUploads);

      final tasks = chunk.map(
        (candidate) => BackupAssetUploadTask(
          candidate: candidate,
          uploader: _uploader,
          onSuccess: onSuccess,
          onError: onError,
          onCurrentAsset: onCurrentAsset,
          onProgress: onProgress,
          pmProgressHandler: pmProgressHandler,
        ),
      );

      final results = await Future.wait(
        tasks.map((task) => task.run(cancelToken)),
      );

      anyErrors |= results.contains(false);

      if (cancelToken.isCancelled) {
        break;
      }
    }

    if (duplicatedAssetIds.isNotEmpty) {
      await _saveDuplicatedAssetIds(duplicatedAssetIds.toList());
    }

    return !anyErrors;
  }
}
