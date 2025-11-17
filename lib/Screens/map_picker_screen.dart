// lib/Screens/map_picker_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

const _gradTop = Color(0xFF0E0F12);
const _gradBottom = Color(0xFF141A22);
const _panel = Color(0xFF15171C);
const _panelBorder = Color(0xFF2A2F38);
const _card = Color(0xFF1C1F26);
const _textPrimary = Colors.white;
const _textSecondary = Color(0xFFB6BDC8);
const _accent = Color(0xFFFF3B30);

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
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: _accent),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          "Standort wählen",
          style: TextStyle(
            color: _textPrimary,
            fontWeight: FontWeight.bold,
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
                myLocationButtonEnabled: true,
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
                  top: BorderSide(color: _panelBorder),
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
                            side: const BorderSide(color: _panelBorder),
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
