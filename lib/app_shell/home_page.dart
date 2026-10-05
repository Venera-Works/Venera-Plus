import 'package:flutter/material.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/consts.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/follow_updates/follow_updates.dart';
import 'package:venera_plus/features/image_favorites/image_favorites.dart';
import 'package:venera_plus/features/search/search.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    var widget = SmoothCustomScrollView(
      slivers: [
        SliverPadding(padding: EdgeInsets.only(top: context.padding.top)),
        const SearchEntry(),
        const SyncStatusSummary(),
        const HistorySummary(),
        const LocalComicsSummary(),
        const FollowUpdatesWidget(),
        const ComicSourceSummary(),
        const ImageFavoritesSummary(),
        SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)),
      ],
    );
    return context.width > changePoint ? widget.paddingHorizontal(8) : widget;
  }
}
