# Garage door driver for Tasmota

Simple two way garage door controller based on Tasmota.

This driver extends Tasmota to act as garage door controller.

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

## Hardware

The prerequisites on the garage door drive are:
- A contact to trigger moving up
- A contact to trigger moving down

Further prerequisits, either by the garage door drive itself or by external contacts (e.g. reed contacts), are:
- A signal marking the closed position
- A signal marking the fully open position

### Example for Berner GA205 door drive

## Configuration and Software Installation

### Install Tasmota

### Configure this software
Steps to configure the software:
1. Edit `make.conf'
2. Edit `params.json`
3. Create `password.txt`

#### make.conf
device_type 	:= berner
target_ip 		:= 172.29.2.197
password 		:= $(shell cat password.txt)

#### params.json

### Configure device and install software


## Implementation

The position logic is completely independant from triggering movements.

