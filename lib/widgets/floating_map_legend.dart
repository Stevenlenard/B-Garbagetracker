import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

enum LegendDock { left, right }

/// Where a floating legend is, kept for the session (survives leaving and reopening
/// the map screen; not written to storage).
class LegendPlacement {
  const LegendPlacement({this.dock = LegendDock.right, this.topFraction = 0.0, this.collapsed = false});

  final LegendDock dock;

  /// 0 = highest safe position, 1 = lowest. A fraction (not pixels) so the legend keeps
  /// its relative place when the screen rotates or the window is resized.
  final double topFraction;
  final bool collapsed;

  LegendPlacement copyWith({LegendDock? dock, double? topFraction, bool? collapsed}) => LegendPlacement(
        dock: dock ?? this.dock,
        topFraction: topFraction ?? this.topFraction,
        collapsed: collapsed ?? this.collapsed,
      );
}

/// Pure geometry of the legend's safe area (unit tested).
class LegendBounds {
  const LegendBounds({required this.area, required this.leftInsets, required this.rightInsets});

  /// Size of the map area the legend floats over.
  final Size area;

  /// What to keep clear when docked on each side: top = header/HUD, bottom = bottom
  /// navigation / panel / map controls, left or right = edge margin (or a side panel).
  final EdgeInsets leftInsets;
  final EdgeInsets rightInsets;

  EdgeInsets insetsFor(LegendDock dock) => dock == LegendDock.left ? leftInsets : rightInsets;

  /// Highest and lowest allowed top for a legend of [height] on [dock]. When the safe band
  /// is shorter than the legend, the legend stays at the top of the band.
  (double, double) topRange(LegendDock dock, double height) {
    final EdgeInsets i = insetsFor(dock);
    final double minTop = i.top;
    final double maxTop = math.max(minTop, area.height - i.bottom - height);
    return (minTop, maxTop);
  }

  /// Height available to the legend on [dock] (its content scrolls beyond this).
  double maxHeight(LegendDock dock) {
    final EdgeInsets i = insetsFor(dock);
    return math.max(48.0, area.height - i.top - i.bottom);
  }

  bool fits(LegendDock dock, double height) {
    final EdgeInsets i = insetsFor(dock);
    return area.height - i.top - i.bottom >= height;
  }

  /// The side actually used: the chosen one, unless its safe band is too short for the
  /// legend and the other side's band is not (e.g. map controls filling one side). The
  /// saved choice is kept, so the legend returns once there is room again.
  /// When neither side fits, the side with the taller band is used (the legend's content
  /// is capped to [maxHeightAnySide] and scrolls).
  LegendDock effectiveDock(LegendDock chosen, double height) {
    final LegendDock other = chosen == LegendDock.left ? LegendDock.right : LegendDock.left;
    if (fits(chosen, height)) return chosen;
    if (fits(other, height)) return other;
    return maxHeight(other) > maxHeight(chosen) ? other : chosen;
  }

  /// Cap for the legend's height: the taller of the two safe bands.
  double get maxHeightAnySide => math.max(maxHeight(LegendDock.left), maxHeight(LegendDock.right));

  double topFor(LegendPlacement p, double height) {
    final (double minTop, double maxTop) = topRange(p.dock, height);
    return minTop + (maxTop - minTop) * p.topFraction.clamp(0.0, 1.0);
  }

  double leftFor(LegendDock dock, double width) {
    final EdgeInsets i = insetsFor(dock);
    return dock == LegendDock.left ? i.left : math.max(0.0, area.width - i.right - width);
  }

  /// Placement after a drag that left the legend's top-left corner at [topLeft]: docks
  /// to the nearer side edge and clamps the height into that side's safe band.
  LegendPlacement settle(LegendPlacement current, Offset topLeft, Size size) {
    final LegendDock dock = (topLeft.dx + size.width / 2) < area.width / 2 ? LegendDock.left : LegendDock.right;
    final (double minTop, double maxTop) = topRange(dock, size.height);
    final double top = topLeft.dy.clamp(minTop, maxTop);
    final double fraction = maxTop > minTop ? (top - minTop) / (maxTop - minTop) : 0.0;
    return current.copyWith(dock: dock, topFraction: fraction);
  }
}

/// A floating, draggable, collapsible legend for a map. Put it in the map's [Stack]
/// (it fills the stack but only the card itself takes touches, so map gestures keep
/// working everywhere else). Moving or collapsing it rebuilds only this widget.
class FloatingMapLegend extends StatefulWidget {
  const FloatingMapLegend({
    super.key,
    required this.sessionId,
    required this.child,
    required this.leftInsets,
    required this.rightInsets,
    this.title = 'Legend',
    this.collapsedPreview,
    this.initialPlacement = const LegendPlacement(),
  });

  /// Placement memory key (one per map screen).
  final String sessionId;

  /// Expanded content (e.g. the truck legend).
  final Widget child;
  final EdgeInsets leftInsets;
  final EdgeInsets rightInsets;
  final String title;

  /// Small widget shown on the collapsed tab (e.g. colour dots).
  final Widget? collapsedPreview;
  final LegendPlacement initialPlacement;

  static final Map<String, LegendPlacement> _session = <String, LegendPlacement>{};

  /// For tests.
  static void resetSession() => _session.clear();

  @override
  State<FloatingMapLegend> createState() => _FloatingMapLegendState();
}

class _FloatingMapLegendState extends State<FloatingMapLegend> {
  final GlobalKey _cardKey = GlobalKey();
  late LegendPlacement _placement;
  Size _cardSize = const Size(150, 44);
  Offset? _dragTopLeft; // free position while a drag is in progress
  LegendDock _shownDock = LegendDock.right; // side actually used (see effectiveDock)

  @override
  void initState() {
    super.initState();
    _placement = FloatingMapLegend._session[widget.sessionId] ?? widget.initialPlacement;
    _shownDock = _placement.dock;
  }

  void _save(LegendPlacement p) {
    _placement = p;
    FloatingMapLegend._session[widget.sessionId] = p;
  }

  void _measure() {
    final Size? s = _cardKey.currentContext?.size;
    if (s != null && s != _cardSize && mounted) setState(() => _cardSize = s);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final LegendBounds bounds = LegendBounds(
        area: Size(constraints.maxWidth, constraints.maxHeight),
        leftInsets: widget.leftInsets,
        rightInsets: widget.rightInsets,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());

      final double left;
      final double top;
      final Offset? drag = _dragTopLeft;
      if (drag != null) {
        // Free movement while dragging, still kept inside the map area.
        left = drag.dx.clamp(0.0, math.max(0.0, bounds.area.width - _cardSize.width));
        top = drag.dy.clamp(0.0, math.max(0.0, bounds.area.height - _cardSize.height));
      } else {
        final LegendPlacement shown =
            _placement.copyWith(dock: bounds.effectiveDock(_placement.dock, _cardSize.height));
        _shownDock = shown.dock;
        left = bounds.leftFor(shown.dock, _cardSize.width);
        top = bounds.topFor(shown, _cardSize.height);
      }

      return Stack(children: [
        AnimatedPositioned(
          duration: drag != null ? Duration.zero : const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          left: left,
          top: top,
          child: PointerInterceptor(
            child: KeyedSubtree(
              key: _cardKey,
              child: _placement.collapsed
                  ? _buildCollapsed(bounds, left, top)
                  : _buildExpanded(bounds, left, top),
            ),
          ),
        ),
      ]);
    });
  }

  Widget _dragArea({required Widget child, required LegendBounds bounds, required double left, required double top}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => setState(() => _dragTopLeft = Offset(left, top)),
      onPanUpdate: (d) => setState(() => _dragTopLeft = (_dragTopLeft ?? Offset(left, top)) + d.delta),
      onPanEnd: (_) => _endDrag(bounds),
      onPanCancel: () => _endDrag(bounds),
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: child),
    );
  }

  void _endDrag(LegendBounds bounds) {
    final Offset? drag = _dragTopLeft;
    setState(() {
      if (drag != null) _save(bounds.settle(_placement, drag, _cardSize));
      _dragTopLeft = null;
    });
  }

  void _setCollapsed(bool collapsed) => setState(() => _save(_placement.copyWith(collapsed: collapsed)));

  static const BoxDecoration _cardDecoration = BoxDecoration(
    color: Color(0xF2FFFFFF),
    borderRadius: BorderRadius.all(Radius.circular(14)),
    boxShadow: [BoxShadow(color: Color(0x26000000), blurRadius: 8, offset: Offset(0, 2))],
  );

  Widget _buildCollapsed(LegendBounds bounds, double left, double top) {
    final bool right = _shownDock == LegendDock.right;
    return Container(
      key: const ValueKey<String>('legend-collapsed'),
      decoration: _cardDecoration,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _dragArea(
            bounds: bounds,
            left: left,
            top: top,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 2, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.drag_indicator_rounded, size: 16, color: Color(0xFF90A4AE)),
                  const SizedBox(width: 2),
                  Text(widget.title, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, color: Color(0xFF455A64))),
                  if (widget.collapsedPreview != null) ...[const SizedBox(width: 6), widget.collapsedPreview!],
                ],
              ),
            ),
          ),
          IconButton(
            key: const ValueKey<String>('legend-expand'),
            tooltip: 'Show legend',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
            onPressed: () => _setCollapsed(false),
            icon: Icon(right ? Icons.chevron_left_rounded : Icons.chevron_right_rounded, size: 20, color: const Color(0xFF00796B)),
          ),
        ],
      ),
    );
  }

  Widget _buildExpanded(LegendBounds bounds, double left, double top) {
    final bool right = _shownDock == LegendDock.right;
    return Container(
      key: const ValueKey<String>('legend-expanded'),
      constraints: BoxConstraints(maxWidth: 210, maxHeight: bounds.maxHeightAnySide),
      decoration: _cardDecoration,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dragArea(
                bounds: bounds,
                left: left,
                top: top,
                child: Padding(
                  key: const ValueKey<String>('legend-handle'),
                  padding: const EdgeInsets.fromLTRB(6, 6, 4, 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.drag_indicator_rounded, size: 16, color: Color(0xFF90A4AE)),
                      const SizedBox(width: 2),
                      Text(widget.title, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, color: Color(0xFF455A64))),
                      const SizedBox(width: 24),
                    ],
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey<String>('legend-collapse'),
                tooltip: 'Hide legend',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () => _setCollapsed(true),
                icon: Icon(right ? Icons.chevron_right_rounded : Icons.chevron_left_rounded, size: 20, color: const Color(0xFF00796B)),
              ),
            ],
          ),
          Flexible(child: SingleChildScrollView(child: widget.child)),
        ],
      ),
    );
  }
}
