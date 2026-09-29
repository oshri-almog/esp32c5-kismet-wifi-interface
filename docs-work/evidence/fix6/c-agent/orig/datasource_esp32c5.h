/*
    This file is part of Kismet

    Kismet is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    Kismet is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Kismet; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*/

#ifndef __DATASOURCE_ESP32C5_H__
#define __DATASOURCE_ESP32C5_H__

#include "config.h"

#define HAVE_ESP32C5_DATASOURCE

#include "kis_datasource.h"

/* ESP32-C5 sniffer boards over their native USB port.
 *
 * One board listens with one of three radios: Wi-Fi on 2.4 and 5 GHz (the
 * default), IEEE 802.15.4 for Zigbee and Thread, or Bluetooth LE advertising.  The
 * source name picks it -- esp32c5-ttyACM0, esp32c5zigbee-ttyACM0,
 * esp32c5btle-ttyACM0, which is also how the helper lists a board, once per radio,
 * since Kismet keeps nothing but the name of a listed interface -- and mode= in
 * the definition overrides the name.  Only one of the three can run at a time: the
 * helper locks the port, and leaves a board whose port is locked out of the list.
 *
 * The helper hands every packet over in a link type Kismet already decodes --
 * radiotap, 802.15.4 without FCS, or BTLE with the radio pseudo-header -- so no
 * packet handling is needed here: the base class takes the per-packet DLT and
 * signal block as they come.
 *
 * The DLT is not fixed per source type, because it follows the mode, so it is left
 * for the open report to set.
 */

class kis_datasource_esp32c5;
typedef std::shared_ptr<kis_datasource_esp32c5> shared_datasource_esp32c5;

class kis_datasource_esp32c5 : public kis_datasource {
public:
    kis_datasource_esp32c5(shared_datasource_builder in_builder) :
        kis_datasource(in_builder) {

        set_int_source_ipc_binary("kismet_cap_esp32c5");
    }

    virtual ~kis_datasource_esp32c5() { };
};


class datasource_esp32c5_builder : public kis_datasource_builder {
public:
    datasource_esp32c5_builder(int in_id) :
        kis_datasource_builder(in_id) {

        register_fields();
        reserve_fields(NULL);
        initialize();
    }

    datasource_esp32c5_builder(int in_id, std::shared_ptr<tracker_element_map> e) :
        kis_datasource_builder(in_id, e) {

        register_fields();
        reserve_fields(e);
        initialize();
    }

    datasource_esp32c5_builder() :
        kis_datasource_builder(0) {

        register_fields();
        reserve_fields(NULL);
        initialize();
    }

    virtual ~datasource_esp32c5_builder() { }

    virtual shared_datasource build_datasource(shared_datasource_builder in_sh_this) override {
        return shared_datasource_esp32c5(new kis_datasource_esp32c5(in_sh_this));
    }

    virtual void initialize() override {
        set_source_type("esp32c5");
        set_source_description("ESP32-C5 sniffer board: Wi-Fi (2.4/5 GHz), 802.15.4, or BTLE advertising");

        set_probe_capable(true);
        set_list_capable(true);
        set_local_capable(true);
        set_remote_capable(true);
        set_passive_capable(false);
        set_tune_capable(true);
        set_hop_capable(true);
    }
};

#endif
