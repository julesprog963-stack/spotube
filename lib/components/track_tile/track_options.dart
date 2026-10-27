import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:shadcn_flutter/shadcn_flutter_extension.dart';
import 'package:spotube/collections/routes.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/ui/button_tile.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/modules/player/sibling_tracks_sheet.dart';
import 'package:spotube/provider/track_options/track_options_provider.dart';

/// [track] must be a [SpotubeFullTrackObject] or [SpotubeLocalTrackObject]
class TrackOptions extends HookConsumerWidget {
  final SpotubeTrackObject track;
  final bool userPlaylist;
  final String? playlistId;
  final Widget? icon;
  final VoidCallback? onTapItem;

  const TrackOptions({
    super.key,
    required this.track,
    this.userPlaylist = false,
    this.playlistId,
    this.icon,
    this.onTapItem,
  }) : assert(
          track is SpotubeFullTrackObject || track is SpotubeLocalTrackObject,
          "Track must be a SpotubeFullTrackObject, SpotubeLocalTrackObject",
        );

  @override
  Widget build(BuildContext context, ref) {
    final mediaQuery = MediaQuery.of(context);

    final trackOptionActions = ref.watch(trackOptionActionsProvider(track));
    final (
      :isBlacklisted,
      :isInDownloadQueue,
      :isInQueue,
      :isActiveTrack,
      :isAuthenticated,
      :isLiked,
      :downloadTask
    ) = ref.watch(trackOptionsStateProvider(track));
    final isLocalTrack = track is SpotubeLocalTrackObject;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        if (isLocalTrack)
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () async {
              await trackOptionActions.action(
                rootNavigatorKey.currentContext!,
                TrackOptionValue.delete,
                playlistId,
              );
              onTapItem?.call();
            },
            leading: const Icon(SpotubeIcons.trash),
            title: Text(context.l10n.delete),
          ),
        if (mediaQuery.smAndDown && !isLocalTrack)
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () async {
              await trackOptionActions.action(
                rootNavigatorKey.currentContext!,
                TrackOptionValue.album,
                playlistId,
              );
              onTapItem?.call();
            },
            leading: const Icon(SpotubeIcons.album),
            title: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.go_to_album),
                Text(
                  track.album.name,
                  style: context.theme.typography.xSmall,
                ),
              ],
            ),
          ),
        if (!isInQueue) ...[
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () async {
              await trackOptionActions.action(
                rootNavigatorKey.currentContext!,
                TrackOptionValue.addToQueue,
                playlistId,
              );
              onTapItem?.call();
            },
            leading: const Icon(SpotubeIcons.queueAdd),
            title: Text(context.l10n.add_to_queue),
          ),
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () async {
              await trackOptionActions.action(
                rootNavigatorKey.currentContext!,
                TrackOptionValue.playNext,
                playlistId,
              );
              onTapItem?.call();
            },
            leading: const Icon(SpotubeIcons.lightning),
            title: Text(context.l10n.play_next),
          ),
        ] else
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () async {
              await trackOptionActions.action(
                rootNavigatorKey.currentContext!,
                TrackOptionValue.removeFromQueue,
                playlistId,
              );
              onTapItem?.call();
            },
            enabled: !isActiveTrack,
            leading: const Icon(SpotubeIcons.queueRemove),
            title: Text(context.l10n.remove_from_queue),
          ),
        if (isAuthenticated && !isLocalTrack)
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () async {
              await trackOptionActions.action(
                rootNavigatorKey.currentContext!,
                TrackOptionValue.favorite,
                playlistId,
              );
              onTapItem?.call();
            },
            leading: isLiked
                ? const Icon(
                    SpotubeIcons.heartFilled,
                    color: Colors.pink,
                  )
                : const Icon(SpotubeIcons.heart),
            title: Text(
              isLiked
                  ? context.l10n.remove_from_favorites
                  : context.l10n.save_as_favorite,
            ),
          ),
        if (isAuthenticated && !isLocalTrack) ...[
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () async {
              await trackOptionActions.action(
                rootNavigatorKey.currentContext!,
                TrackOptionValue.startRadio,
                playlistId,
              );
              onTapItem?.call();
            },
            leading: const Icon(SpotubeIcons.radio),
            title: Text(context.l10n.start_a_radio),
          ),
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () async {
              await trackOptionActions.action(
                rootNavigatorKey.currentContext!,
                TrackOptionValue.addToPlaylist,
                playlistId,
              );
              onTapItem?.call();
            },
            leading: const Icon(SpotubeIcons.playlistAdd),
            title: Text(context.l10n.add_to_playlist),
          ),
        ],
        if (userPlaylist && isAuthenticated && !isLocalTrack)
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () async {
              await trackOptionActions.action(
                rootNavigatorKey.currentContext!,
                TrackOptionValue.removeFromPlaylist,
                playlistId,
              );
              onTapItem?.call();
            },
            leading: const Icon(SpotubeIcons.removeFilled),
            title: Text(context.l10n.remove_from_playlist),
          ),
        if (!isLocalTrack)
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () async {
              await trackOptionActions.action(
                rootNavigatorKey.currentContext!,
                TrackOptionValue.download,
                playlistId,
              );
              onTapItem?.call();
            },
            enabled: !isInDownloadQueue,
            leading: isInDownloadQueue
                ? StreamBuilder(
                    stream: downloadTask?.downloadedBytesStream,
                    builder: (context, snapshot) {
                      final progress = downloadTask?.totalSizeBytes == null ||
                              downloadTask?.totalSizeBytes == 0
                          ? 0
                          : (snapshot.data ?? 0) /
                              downloadTask!.totalSizeBytes!;
                      return CircularProgressIndicator(
                        value: progress.toDouble(),
                      );
                    },
                  )
                : const Icon(SpotubeIcons.download),
            title: Text(context.l10n.download_track),
          ),
        if (!isLocalTrack && track is SpotubeFullTrackObject)
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () {
              onTapItem?.call();
              final fullTrack = track as SpotubeFullTrackObject;
              final screenSize = MediaQuery.sizeOf(context);
              if (screenSize.mdAndUp) {
                showPopover(
                  alignment: Alignment.center,
                  context: context,
                  builder: (context) {
                    return SurfaceCard(
                      padding: EdgeInsets.zero,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: 600,
                          maxWidth: 500,
                        ),
                        child: SiblingTracksSheet(
                          floating: false,
                          customTrack: fullTrack,
                        ),
                      ),
                    );
                  },
                );
              } else {
                openDrawer(
                  context: context,
                  position: OverlayPosition.bottom,
                  draggable: true,
                  showDragHandle: true,
                  borderRadius: context.theme.borderRadiusMd,
                  transformBackdrop: false,
                  builder: (context) {
                    return ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
                      ),
                      child: SiblingTracksSheet(
                        floating: false,
                        customTrack: fullTrack,
                      ),
                    );
                  },
                );
              }
            },
            leading: const Icon(SpotubeIcons.alternativeRoute),
            title: Text(context.l10n.alternative_track_sources),
          ),
        if (!isLocalTrack)
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () async {
              await trackOptionActions.action(
                rootNavigatorKey.currentContext!,
                TrackOptionValue.blacklist,
                playlistId,
              );
              onTapItem?.call();
            },
            leading: Icon(
              SpotubeIcons.playlistRemove,
              color: isBlacklisted != true ? Colors.red[400] : null,
            ),
            title: Text(
              isBlacklisted == true
                  ? context.l10n.remove_from_blacklist
                  : context.l10n.add_to_blacklist,
              style: TextStyle(
                color: isBlacklisted != true ? Colors.red[400] : null,
              ),
            ),
          ),
        if (!isLocalTrack)
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () async {
              await trackOptionActions.action(
                rootNavigatorKey.currentContext!,
                TrackOptionValue.share,
                playlistId,
              );
              onTapItem?.call();
            },
            leading: const Icon(SpotubeIcons.share),
            title: Text(context.l10n.share),
          ),
        if (!isLocalTrack)
          ButtonTile(
            style: ButtonVariance.menu,
            onPressed: () async {
              await trackOptionActions.action(
                rootNavigatorKey.currentContext!,
                TrackOptionValue.details,
                playlistId,
              );
              onTapItem?.call();
            },
            leading: const Icon(SpotubeIcons.info),
            title: Text(context.l10n.details),
          ),
      ],
    );
  }
}
