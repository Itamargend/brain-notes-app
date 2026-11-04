# Garden soil sensor
Cheap ESP32 board + capacitive moisture probe, reports every 15 min.

## Parts
- ESP32-C3 mini
- Capacitive soil probe v2.0
- 18650 cell + holder
- Small solar panel (5 V, 1 W)

## Notes
- Calibrate dry = air, wet = glass of water. Raw values drift ~3% with temperature.
- Deep sleep gets battery life to roughly 5 weeks without the panel.
