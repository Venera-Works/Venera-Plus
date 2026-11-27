import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/components/image.dart';
import 'package:venera_plus/components/loading.dart';
import 'package:venera_plus/components/rich_comment_content.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/components/side_bar.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/image_provider/cached_image.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'package:venera_plus/foundation/keyword_filter.dart';

import 'reader_page.dart';

KeywordFilter _commentFilter() => KeywordFilter.fromSettings({
  'blockedCommentWords': appdata.settings['blockedCommentWords'],
  'blockedCommentWordRules': appdata.settings['blockedCommentWordRules'],
}, comments: true);

mixin _ChapterCommentsPagination<T extends StatefulWidget> on State<T> {
  bool _loading = true;
  String? _firstPageError;
  String? _nextPageError;
  final _allComments = <Comment>[];
  List<Comment> _comments = [];
  Object? _pageRequest;
  int _page = 0;
  int? _maxPage;

  bool get _hasMore => _maxPage == null || _page < _maxPage!;

  Future<Res<List<Comment>>> _fetchComments(int page);

  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(_onKeywordSettingsChanged);
    unawaited(_loadPage(1));
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_onKeywordSettingsChanged);
    super.dispose();
  }

  void _onKeywordSettingsChanged() {
    if (!_loading) setState(_filterComments);
  }

  void _filterComments() {
    final filter = _commentFilter();
    _comments = _allComments
        .where((comment) => !filter.blocksComment(comment.content))
        .toList();
  }

  void _reloadComments() {
    setState(() {
      _loading = true;
      _firstPageError = null;
      _nextPageError = null;
    });
    unawaited(_loadPage(1));
  }

  void _loadMoreComments() {
    if (_loading ||
        _firstPageError != null ||
        !_hasMore ||
        _pageRequest != null) {
      return;
    }
    setState(() => _nextPageError = null);
    unawaited(_loadPage(_page + 1));
  }

  Future<void> _loadPage(int page) async {
    final request = Object();
    _pageRequest = request;
    Res<List<Comment>> result;
    try {
      result = await _fetchComments(page);
    } catch (error) {
      result = Res.error(error.toString());
    }
    // Posting a comment can start a fresh first page during an earlier request.
    if (!mounted || !identical(request, _pageRequest)) return;
    setState(() {
      _pageRequest = null;
      _loading = false;
      if (result.error) {
        if (page == 1) {
          _firstPageError = result.errorMessage;
        } else {
          _nextPageError = result.errorMessage;
        }
        return;
      }
      if (page == 1) {
        _allComments.clear();
        _maxPage = null;
      }
      _allComments.addAll(result.data);
      _filterComments();
      _page = page;
      if (result.subData case final int maxPage) {
        _maxPage = maxPage;
      } else if (_maxPage == null && result.data.isEmpty) {
        _maxPage = page;
      }
    });
  }

  Widget? _buildInitialCommentStatus() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_firstPageError case final error?) {
      return NetworkError(
        message: error,
        retry: _reloadComments,
        withAppbar: false,
      );
    }
    return null;
  }

  Widget _buildCommentsFooter({bool autoLoad = true}) {
    if (_nextPageError case final error?) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            TextButton(onPressed: _loadMoreComments, child: Text('Retry'.tl)),
          ],
        ),
      );
    }
    if (_pageRequest != null) return const ListLoadingIndicator();
    if (!autoLoad) {
      return Center(
        child: TextButton(
          onPressed: _loadMoreComments,
          child: Text('Load more comments'.tl),
        ),
      );
    }
    final page = _page;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _page == page && _nextPageError == null) {
        _loadMoreComments();
      }
    });
    return const ListLoadingIndicator();
  }
}

class ChapterCommentsPage extends StatefulWidget {
  const ChapterCommentsPage({
    super.key,
    required this.comicId,
    required this.epId,
    required this.source,
    required this.comicTitle,
    required this.chapterTitle,
    this.replyComment,
  });

  final String comicId;
  final String epId;
  final ComicSource source;
  final String comicTitle;
  final String chapterTitle;
  final Comment? replyComment;

  @override
  State<ChapterCommentsPage> createState() => _ChapterCommentsPageState();
}

class _ChapterCommentsPageState extends State<ChapterCommentsPage>
    with _ChapterCommentsPagination<ChapterCommentsPage> {
  var controller = TextEditingController();
  bool sending = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Future<Res<List<Comment>>> _fetchComments(int page) =>
      widget.source.chapterCommentsLoader!(
        widget.comicId,
        widget.epId,
        page,
        widget.replyComment?.id,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: Appbar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Chapter Comments".tl, style: ts.s18),
            Text(widget.chapterTitle, style: ts.s12),
          ],
        ),
        style: AppbarStyle.shadow,
      ),
      body: buildBody(context),
    );
  }

  Widget buildBody(BuildContext context) {
    if (_buildInitialCommentStatus() case final status?) {
      return status;
    } else {
      var showAvatar =
          _comments.any((e) {
            return e.avatar != null;
          }) ||
          (widget.replyComment?.avatar != null);
      return Column(
        children: [
          Expanded(
            child: SmoothScrollProvider(
              builder: (context, controller, physics) {
                return ListView.builder(
                  controller: controller,
                  physics: physics,
                  primary: false,
                  padding: EdgeInsets.zero,
                  itemCount: _comments.length + (_hasMore ? 2 : 1),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      if (widget.replyComment != null) {
                        return Column(
                          children: [
                            _ChapterCommentTile(
                              comment: widget.replyComment!,
                              source: widget.source,
                              comicId: widget.comicId,
                              epId: widget.epId,
                              showAvatar: showAvatar,
                              showActions: false,
                            ),
                            const SizedBox(height: 8),
                            Container(
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    color: context.colorScheme.outlineVariant,
                                    width: 0.6,
                                  ),
                                ),
                              ),
                              child: Text("Replies".tl, style: ts.s18),
                            ),
                          ],
                        );
                      } else {
                        return const SizedBox();
                      }
                    }
                    index--;

                    if (index == _comments.length) {
                      return _buildCommentsFooter();
                    }

                    return _ChapterCommentTile(
                      comment: _comments[index],
                      source: widget.source,
                      comicId: widget.comicId,
                      epId: widget.epId,
                      showAvatar: showAvatar,
                    );
                  },
                );
              },
            ),
          ),
          buildBottom(context),
        ],
      );
    }
  }

  Widget buildBottom(BuildContext context) {
    if (widget.source.sendChapterCommentFunc == null) {
      return const SizedBox(height: 0);
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Material(
        color: context.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  hintText: "Comment".tl,
                ),
                minLines: 1,
                maxLines: 5,
              ),
            ),
            if (sending)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                tooltip: 'Submit'.tl,
                onPressed: () async {
                  if (controller.text.isEmpty) {
                    return;
                  }
                  setState(() {
                    sending = true;
                  });
                  var b = await widget.source.sendChapterCommentFunc!(
                    widget.comicId,
                    widget.epId,
                    controller.text,
                    widget.replyComment?.id,
                  );
                  if (!mounted) return;
                  if (!b.error) {
                    controller.clear();
                    sending = false;
                    _reloadComments();
                  } else {
                    context.showMessage(message: b.errorMessage ?? "Error");
                    setState(() {
                      sending = false;
                    });
                  }
                },
                icon: Icon(
                  Icons.send,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
          ],
        ).paddingLeft(16).paddingRight(4),
      ),
    );
  }
}

class _ChapterCommentTile extends StatefulWidget {
  const _ChapterCommentTile({
    required this.comment,
    required this.source,
    required this.comicId,
    required this.epId,
    required this.showAvatar,
    this.showActions = true,
  });

  final Comment comment;
  final ComicSource source;
  final String comicId;
  final String epId;
  final bool showAvatar;
  final bool showActions;

  @override
  State<_ChapterCommentTile> createState() => _ChapterCommentTileState();
}

class _ChapterCommentTileState extends State<_ChapterCommentTile> {
  @override
  void initState() {
    likes = widget.comment.score ?? 0;
    isLiked = widget.comment.isLiked ?? false;
    voteStatus = widget.comment.voteStatus;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showAvatar)
            Container(
              width: 36,
              height: 36,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: Theme.of(context).colorScheme.secondaryContainer,
              ),
              child: widget.comment.avatar == null
                  ? null
                  : AnimatedImage(
                      image: CachedImageProvider(
                        widget.comment.avatar!,
                        sourceKey: widget.source.key,
                      ),
                    ),
            ).paddingRight(8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.comment.userName, style: ts.bold),
                if (widget.comment.time != null)
                  Text(widget.comment.time!, style: ts.s12),
                const SizedBox(height: 4),
                _CommentContent(text: widget.comment.content),
                buildActions(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildActions() {
    if (!widget.showActions) {
      return const SizedBox();
    }
    if (widget.comment.score == null && widget.comment.replyCount == null) {
      return const SizedBox();
    }
    return SizedBox(
      height: 36,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (widget.comment.score != null &&
              widget.source.voteCommentFunc != null)
            buildVote(),
          if (widget.comment.score != null &&
              widget.source.likeCommentFunc != null)
            buildLike(),
          // Only show reply button if comment has both id and replyCount
          if (widget.comment.replyCount != null && widget.comment.id != null)
            buildReply(),
        ],
      ),
    ).paddingTop(8);
  }

  Widget buildReply() {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ClickInkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          // Get the parent page's widget to access comicTitle and chapterTitle
          var parentState = context
              .findAncestorStateOfType<_ChapterCommentsPageState>();
          showSideBar(
            context,
            ChapterCommentsPage(
              comicId: widget.comicId,
              epId: widget.epId,
              source: widget.source,
              comicTitle: parentState?.widget.comicTitle ?? '',
              chapterTitle: parentState?.widget.chapterTitle ?? '',
              replyComment: widget.comment,
            ),
            showBarrier: false,
          );
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_comment_outlined, size: 16),
            const SizedBox(width: 8),
            Text(widget.comment.replyCount.toString()),
          ],
        ).padding(const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
      ),
    );
  }

  bool isLiking = false;
  bool isLiked = false;
  var likes = 0;

  Widget buildLike() {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ClickInkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          if (isLiking) return;
          setState(() {
            isLiking = true;
          });
          var res = await widget.source.likeCommentFunc!(
            widget.comicId,
            widget.epId,
            widget.comment.id!,
            !isLiked,
          );
          if (res.success) {
            isLiked = !isLiked;
            likes += isLiked ? 1 : -1;
          } else {
            context.showMessage(message: res.errorMessage ?? 'Error'.tl);
          }
          setState(() {
            isLiking = false;
          });
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLiking)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(),
              )
            else if (isLiked)
              Icon(
                Icons.favorite,
                size: 16,
                color: context.useTextColor(Colors.red),
              )
            else
              const Icon(Icons.favorite_border, size: 16),
            const SizedBox(width: 8),
            Text(likes.toString()),
          ],
        ).padding(const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
      ),
    );
  }

  int? voteStatus;
  bool isVotingUp = false;
  bool isVotingDown = false;

  void vote(bool isUp) async {
    if (isVotingUp || isVotingDown) return;
    setState(() {
      if (isUp) {
        isVotingUp = true;
      } else {
        isVotingDown = true;
      }
    });
    var isCancel = (isUp && voteStatus == 1) || (!isUp && voteStatus == -1);
    var res = await widget.source.voteCommentFunc!(
      widget.comicId,
      widget.epId,
      widget.comment.id!,
      isUp,
      isCancel,
    );
    if (res.success) {
      if (isCancel) {
        voteStatus = 0;
      } else {
        if (isUp) {
          voteStatus = 1;
        } else {
          voteStatus = -1;
        }
      }
      widget.comment.voteStatus = voteStatus;
      widget.comment.score = res.data ?? widget.comment.score;
    } else {
      context.showMessage(message: res.errorMessage ?? 'Error'.tl);
    }
    setState(() {
      isVotingUp = false;
      isVotingDown = false;
    });
  }

  Widget buildVote() {
    var upColor = context.colorScheme.outline;
    if (voteStatus == 1) {
      upColor = context.useTextColor(Colors.red);
    }
    var downColor = context.colorScheme.outline;
    if (voteStatus == -1) {
      downColor = context.useTextColor(Colors.blue);
    }

    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Button.icon(
            isLoading: isVotingUp,
            icon: const Icon(Icons.arrow_upward),
            size: 18,
            color: upColor,
            onPressed: () => vote(true),
          ),
          const SizedBox(width: 4),
          Text(widget.comment.score.toString()),
          const SizedBox(width: 4),
          Button.icon(
            isLoading: isVotingDown,
            icon: const Icon(Icons.arrow_downward),
            size: 18,
            color: downColor,
            onPressed: () => vote(false),
          ),
        ],
      ),
    );
  }
}

class _CommentContent extends StatelessWidget {
  const _CommentContent({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (!text.contains('<') && !text.contains('http')) {
      return SelectableText(text);
    } else {
      return RichCommentContent(text: text);
    }
  }
}

/// Embedded chapter comments page for displaying at end of chapter in gallery mode.
class EmbeddedChapterCommentsPage extends StatefulWidget {
  const EmbeddedChapterCommentsPage({
    super.key,
    required this.comicId,
    required this.epId,
    required this.source,
    required this.comicTitle,
    required this.chapterTitle,
  });

  final String comicId;
  final String epId;
  final ComicSource source;
  final String comicTitle;
  final String chapterTitle;

  @override
  State<EmbeddedChapterCommentsPage> createState() =>
      _EmbeddedChapterCommentsPageState();
}

class _EmbeddedChapterCommentsPageState
    extends State<EmbeddedChapterCommentsPage>
    with _ChapterCommentsPagination<EmbeddedChapterCommentsPage> {
  var textController = TextEditingController();
  bool sending = false;
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();
  late final _inputPauseReason = ('chapter_comment_input', _inputFocusNode);
  late final ReaderState? _reader;
  bool _pausedForInput = false;

  @override
  void initState() {
    super.initState();
    _reader = context.findAncestorStateOfType<ReaderState>();
    _inputFocusNode.addListener(_updateAutoReadingPause);
  }

  void _updateAutoReadingPause() {
    final reader = _reader;
    if (reader == null) return;
    final shouldPause = _inputFocusNode.hasFocus || sending;
    if (_pausedForInput == shouldPause) return;
    _pausedForInput = shouldPause;
    reader.autoReading.pause(_inputPauseReason, shouldPause);
  }

  @override
  void dispose() {
    _inputFocusNode.dispose();
    _scrollController.dispose();
    final reader = _reader;
    if (_pausedForInput && reader != null) {
      final pauseReason = _inputPauseReason;
      // 释放暂停会通知阅读器重建，等组件树解锁后再执行。
      scheduleMicrotask(() {
        if (reader.mounted) {
          reader.autoReading.pause(pauseReason, false);
        }
      });
    }
    textController.dispose();
    super.dispose();
  }

  @override
  Future<Res<List<Comment>>> _fetchComments(int page) =>
      widget.source.chapterCommentsLoader!(
        widget.comicId,
        widget.epId,
        page,
        null,
      );

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      color: context.colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildBody()),
            _buildBottom(),
            SizedBox(height: bottomInset),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              Navigator.of(context).pop();
            },
            tooltip: "Exit".tl,
          ),
          const SizedBox(width: 4),
          Icon(Icons.comment, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Chapter Comments".tl, style: ts.s18),
                Text(widget.chapterTitle, style: ts.s12),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_buildInitialCommentStatus() case final status?) return status;
    if (_comments.isEmpty) {
      return _hasMore
          ? _buildCommentsFooter(autoLoad: false)
          : Center(child: Text('No comments yet'.tl, style: ts.s14));
    }
    return _buildCommentsList(_comments.any((e) => e.avatar != null));
  }

  Widget _buildCommentsList(bool showAvatar) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final crossAxisCount = isLandscape ? 2 : 1;

    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      thickness: 8,
      child: MasonryGridView.count(
        controller: _scrollController,
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: 0,
        crossAxisSpacing: 0,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: _comments.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _comments.length) {
            return _buildCommentsFooter();
          }
          return _ChapterCommentTile(
            comment: _comments[index],
            source: widget.source,
            comicId: widget.comicId,
            epId: widget.epId,
            showAvatar: showAvatar,
          );
        },
      ),
    );
  }

  Future<void> _sendComment() async {
    if (sending || textController.text.isEmpty) return;
    setState(() => sending = true);
    _updateAutoReadingPause();
    try {
      final result = await widget.source.sendChapterCommentFunc!(
        widget.comicId,
        widget.epId,
        textController.text,
        null,
      );
      if (!mounted) return;
      if (result.error) {
        context.showMessage(message: result.errorMessage ?? 'Error'.tl);
        return;
      }
      textController.clear();
      _reloadComments();
    } finally {
      if (mounted) {
        setState(() => sending = false);
        _updateAutoReadingPause();
      }
    }
  }

  Widget _buildBottom() {
    if (widget.source.sendChapterCommentFunc == null) {
      return const SizedBox(height: 0);
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Material(
        color: context.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: textController,
                focusNode: _inputFocusNode,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  hintText: "Comment".tl,
                ),
                minLines: 1,
                maxLines: 5,
              ),
            ),
            if (sending)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                tooltip: 'Submit'.tl,
                onPressed: _sendComment,
                icon: Icon(
                  Icons.send,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
          ],
        ).paddingLeft(16).paddingRight(4),
      ),
    );
  }
}
