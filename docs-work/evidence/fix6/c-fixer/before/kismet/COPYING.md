# Licence of this directory

The files in `kismet/` are **GPL-2.0-or-later**, not MIT like the rest of this repository.

They are written to become part of Kismet, which is licensed under the GNU General Public License
version 2 or later, and the capture helper links against Kismet's capture framework. Each file
carries Kismet's licence header. See Kismet's `LICENSE` or <https://www.gnu.org/licenses/gpl-2.0.html>.

- `datasource_esp32c5.h`: the server-side source type
- `capture_esp32c5/`: the capture helper, `kismet_cap_esp32c5`
- `add-to-kismet.sh`: copies the above into a Kismet source tree and wires them into its build
