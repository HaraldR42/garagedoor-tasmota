# Garage door driver for Tasmota ESP32

Simple two way garage door controller based on Tasmota ESP32.

This driver extends Tasmota to act as garage door controller.
The extension is written in the "Berry" language avaible on Tasmota for ESP32.

## Features of the controller
- MQTT states for
  - Logical door position (open, closing, closing, opening, partial open / unknown)
  - Last time to open
  - Last time to close
  - Calculated door position during moving (not really sensed, just calculated from moving time)
- Self-calibrating time for opening/closing
- Persisting opening/closing time, optional periodically
- Web button to reset opening/closing calibration
- Optional HomeAssistant integration as extra MQTT "Cover" Device (in addition to Tasmota's integration)

# Hardware

You'll need an ESP32 device with at least 4MB flash size, two available digital inputs and two relays.

This project assumes using a __ESP32_Relay_X2__ board, like in https://templates.blakadder.com/ESP32_Relay_X2.html. It features two relays, an ESP32-WROOM-32E and a variable DC voltage input (typ. 5-30V).
You'll find boards using the same design on almost any online platform.

The prerequisites on the garage door drive are:
- A contact to trigger moving up
- A contact to trigger moving down

Further prerequisits, either by the garage door drive itself or by external contacts (e.g. reed contacts), are:
- A signal marking the closed position
- A signal marking the fully open position

## Example for Berner GA205 door drive

The Berner GA205 has input terminals for an external remote control and also supplies 24V DC power. Furthermore it has a multi purpose relay that can be programmed to signal the door closed position.
Therefore you need only one additional reed contact to determine the fully open position.

Using the ESP32_Relay_X2 board, the wiring is as follows:

| Berner GA205<br>or sensor | ESP32_Relay_X2<br>terminal/pin | Other | Tasmota name | Function |
| ---: | ---: | ---: | :--- | :--- |
| 20 | GND |  |  | GND |
| 5 | Vcc |  |  | +24V |
| 21 | NO1 |  | POWER1 | Trigger open |
|  | COM1 | GND |  |  |
| 23 | NO2 |  | POWER2 | Trigger close |
|  | COM2 | GND |  |  |
| Reed sensor 1 | G19 |  | IS_OPEN | Fully open sensor |
| Reed sensor 1 |  | GND |  |  |
| 1 | G21 |  | IS_CLOSED | Closed sensor |
| 2 |  | GND |  |  |

On the door drive we need to set:

| Menu | Value | Effect |
| ---: | ---: | :--- |
| 01 | 3 | Option relay KL2 signal door closed |
| 17 | 1 | Channel1 -> Open/Stop/Open<br>Channel2 -> Close/Stop/Close |

# Configuration and Software Installation

## Install Tasmota

## Configure this software
Steps to configure the software:
1. Edit `make.conf`
2. Edit `params.json`
3. Create `password.txt`

### make.conf
In `make.conf` adapt to following settings:

| Parameter | Explanation |
| :--- | :--- |
| `device_type` | Replaces "tasmota" in the naming of the ESP32 device<br/>For example, use vendor of your drive |
| `target_ip` | The IP address your received in the previous step. |
| `mqtt_host` | Your mqtt broker. |
| `full_topic` | The base topic path for this device. |

### params.json
In `params.conf` adapt to following settings:

| Module specific ||
| :--- | :--- |
| `persisting_cycle_minutes` | Period for automatic persisting opening/closing. times<BR>_Attention: Writing too often wears out the flash memory!_<BR>Set to `0` to disable. You can manually trigger persisting values via the web interface. |
| __Home Assistant related__ ||
| `homeassistant_enabled` | Bool to enable Home Assistant auto discovery. |
| `ha_name` | UI name of your device. |
| `ha_discovery_base` | MQTT path where discovery information gets published. |
| `ha_doordrive_manufacturer` | Manufacturer of your door drive. Just informal. |
| `ha_doordrive_model` | Model of your door drive. Just informal. |
| `ha_doordrive_serial_number` | Serial number of your door drive. Just informal. |
| __Tasmota related__
| `tasmota_relay_power_num_up` | Number of the Tasmota relay for moving up. |
| `tasmota_relay_power_num_down` | Number of the Tasmota relay for moving down. |
| `tasmota_open_sensor_name` | Tasmota name of the switch indicating the door is fully open. Safe to leave untouched. |
| `tasmota_closed_sensor_name` | Tasmota name of the switch indicating the door is closed. Safe to leave untouched. |

### password.txt
Create a file named `password.txt` which holds the web password of your Tasmota device.
_Just a single line, please!_

## Configure device and install software


# Implementation

The position logic is completely independant from triggering movements.

