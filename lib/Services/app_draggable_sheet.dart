// =======================
// app_draggable_sheet.dart
// =======================
import 'dart:math' as math;
import 'package:flutter/material.dart';

class AppDraggableSheet extends StatefulWidget {
  const AppDraggableSheet({
    super.key,
    required this.childBuilder,

    // Grund-Feeling:
    this.initialChildSize = 0.62,
    this.minChildSize = 0.25,
    this.maxChildSize = 0.98,
    this.snapSizes = const [0.62, 0.98],

    // Look:
    this.panelColor = const Color(0xCC090B10), // ✅ transparent möglich
    this.borderColor = const Color(0x22FFFFFF),
    this.handleColor = const Color(0x33FFFFFF),
    this.topRadius = 22,

    // ✅ wichtig: so hoch wie nötig, wenn Inhalt größer -> maxChildSize
    this.autoFit = true,
  });

  final Widget Function(BuildContext context, ScrollController controller)
  childBuilder;

  final double initialChildSize;
  final double minChildSize;
  final double maxChildSize;
  final List<double> snapSizes;

  final Color panelColor;
  final Color borderColor;
  final Color handleColor;
  final double topRadius;

  final bool autoFit;

  @override
  State<AppDraggableSheet> createState() => _AppDraggableSheetState();
}

class _AppDraggableSheetState extends State<AppDraggableSheet> {
  final DraggableScrollableController _sheetController =
  DraggableScrollableController();
  final GlobalKey _measureKey = GlobalKey();

  double? _lastTarget;

  double _clamp(double v, double lo, double hi) => math.max(lo, math.min(hi, v));

  void _runAutoFit(BoxConstraints constraints) {
    if (!widget.autoFit) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final ctx = _measureKey.currentContext;
      if (ctx == null) return;

      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;

      final contentH = box.size.height;

      // handle + spacings (oben)
      const chromeH = 10 + 5 + 8;
      final wantedPx = contentH + chromeH;

      final availablePx = constraints.maxHeight;
      if (availablePx <= 0) return;

      final wantedFrac =
      _clamp(wantedPx / availablePx, widget.minChildSize, widget.maxChildSize);

      // jitter vermeiden
      if (_lastTarget != null && (wantedFrac - _lastTarget!).abs() < 0.02) return;
      _lastTarget = wantedFrac;

      final target = wantedFrac >= widget.maxChildSize - 0.01
          ? widget.maxChildSize
          : wantedFrac;

      if (_sheetController.isAttached) {
        _sheetController.animateTo(
          target,
          duration: const Duration(milliseconds: 170),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _runAutoFit(constraints);

          return DraggableScrollableSheet(
            controller: _sheetController,
            expand: false,
            initialChildSize: widget.initialChildSize,
            minChildSize: widget.minChildSize,
            maxChildSize: widget.maxChildSize,

            snap: true,
            snapSizes: widget.snapSizes,
            shouldCloseOnMinExtent: true, // ✅ ganz runter -> schließen

            builder: (context, scrollController) {
              return ClipRRect(
                borderRadius:
                BorderRadius.vertical(top: Radius.circular(widget.topRadius)),
                child: Container(
                  decoration: BoxDecoration(
                    color: widget.panelColor,
                    borderRadius: BorderRadius.vertical(
                        top: Radius.circular(widget.topRadius)),
                    border: Border.all(color: widget.borderColor),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      Container(
                        width: 46,
                        height: 5,
                        decoration: BoxDecoration(
                          color: widget.handleColor,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(height: 8),

                      // ✅ Messen + ScrollController MUSS in den Content
                      Expanded(
                        child: KeyedSubtree(
                          key: _measureKey,
                          child: widget.childBuilder(context, scrollController),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
