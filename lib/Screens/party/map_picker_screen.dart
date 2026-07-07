// lib/Screens/map_picker_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../Theme/app_theme.dart';
import '../../l10n/lang.dart';

const _gradTop = AppColors.bgTop;
const _gradBottom = AppColors.bgBottom;
const _panel = Color(0xFF15171C);
const _textPrimary = AppColors.text;
const _textSecondary = AppColors.muted;
const _accent = AppColors.accent;

class MapPickerScreen extends StatefulWidget {
  final LatLng initial;

  const MapPickerScreen({super.key, required this.initial});

  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen> {
  LatLng? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: langNotifier,
      builder: (context, _, __) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final markers = <Marker>{
      if (_selected != null)
        Marker(
          markerId: const MarkerId('selected'),
          position: _selected!,
        ),
    };

    return Scaffold(
      backgroundColor: _gradTop,
      appBar: AppBar(
        backgroundColor: _panel,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: _accent),
          onPressed: () => Navigator.pop(context),
        ),
        centerTitle: true,
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: AppRadius.fullBr,
            border: Border.all(color: AppColors.accentBorder2, width: 1),
          ),
          child: Text(
            Lang.t('map_picker_header'),
            style: const TextStyle(
              color: _textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: -0.2,
            ),
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [_gradTop, _gradBottom],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: GoogleMap(
                initialCameraPosition: CameraPosition(
                  target: _selected ?? widget.initial,
                  zoom: 13,
                ),
                myLocationButtonEnabled: false,
                myLocationEnabled: false,
                zoomControlsEnabled: true,
                markers: markers,
                onTap: (pos) {
                  HapticFeedback.selectionClick();
                  setState(() => _selected = pos);
                },
              ),
            ),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: _panel,
                border: const Border(
                  top: BorderSide(color: AppColors.accentBorder),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _selected == null
                        ? "Tippe auf die Karte, um einen Punkt zu setzen."
                        : "Gewählter Punkt: "
                        "${_selected!.latitude.toStringAsFixed(5)}, "
                        "${_selected!.longitude.toStringAsFixed(5)}",
                    style: const TextStyle(color: _textSecondary),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close, color: Colors.white70),
                          label: const Text(
                            "Abbrechen",
                            style: TextStyle(color: Colors.white70),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: AppColors.accentBorder),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _selected == null
                              ? null
                              : () {
                            // WICHTIG: direkt LatLng zurückgeben
                            Navigator.pop<LatLng>(context, _selected!);
                          },
                          icon: const Icon(Icons.check_circle_outline),
                          label: const Text("Übernehmen"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _accent,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey[700],
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
