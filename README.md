# 🔄 ProtonSpin

A robust and automated Bash script to continuously rotate OpenVPN connections. Designed with high privacy, it features a Kill Switch via UFW, DNS leak protection, and temporary IPv6 blocking at kernel level.

Script tested on **Arch Linux** using **Proton VPN** `.ovpn` configuration files.

## ✨ Key Features

*   **Automatic Rotation:** Randomly changes the VPN server every `X` seconds (default 360s).
*   **Strict UFW Kill Switch:** Absolutely blocks all incoming and outgoing traffic that doesn't pass through the VPN interface.
*   **Anti Leaks:** Blocks IPv6 traffic at the `sysctl` level and routes DNS through the tunnel to prevent *DNS leaks*.
*   **Failover Resilience:** Checks the new IP connectivity using multiple services (ifconfig.me, ipify, icanhazip). If the connection fails, it rotates to a new server.
*   **Auto Cleanup:** Uses locks to prevent multiple concurrent executions and handles interruptions (Ctrl+C) smoothly, restoring your system (UFW, DNS, IPv6) to its original state.

## 📋 Prerequisites

You will need the following packages installed on your system:

*   `bash`, `ufw`, `openvpn`, `curl`, `iproute2` (`ip` command), `awk`, `grep`, `sed`, `coreutils` (`realpath`, `stat`), `glibc` (`getent`), `util-linux` (`flock`).

Make sure UFW is enabled and running correctly on your OS before executing the script.

## 🚀 Installation and Setup

1. **Clone this repository:**
   ```bash
   git clone https://github.com/D4vKry/ProtonSpin.git
   cd openvpn-rotator
   ```

    Prepare the VPN directory:
    By default, the script looks for a folder named proton in the same directory.
    ```bash

    mkdir proton
    ```
    Add your configuration files:
    Copy all your .ovpn files (downloaded from Proton VPN or another provider) inside the proton folder.

    Set up your credentials:
    Create a file named creds.txt inside the proton folder. The first line must be your username and the second your password.
    ```bash

    nvim proton/creds.txt
    ```
    Note: For security reasons, the script requires this file to have restrictive permissions. Apply the correct permissions:
    ```bash

    chmod 600 proton/creds.txt
    ```
## 🛠️ Usage

To start the rotator, simply run the script with root privileges:
```bash

chmod +x ProtonSpin.sh
sudo ./ProtonSpin.sh
```
The script will take control of UFW, backup your current rules, bring up the tunnel, and automatically rotate the configurations. To stop it, press Ctrl+C. The script will clean and leave your system exactly as it was.

<img width="1476" height="523" alt="image" src="https://github.com/user-attachments/assets/a71bbbe2-179d-412b-a399-607e1fa2a8c4" />


## Emergency Mode (Reset)

If for any reason (like a sudden power loss or hard crash) the script stops abnormally and your internet remains blocked by the Kill Switch, you can restore the system using the reset flag:

```bash

sudo ./ProtonSpin.sh --reset
```
## ⚙️ Advanced Configuration

You can modify the variables at the top of the script (USER CONFIG) to fit your needs:

    FOLDER_VPNS: Path to the folder containing the .ovpn files.

    FILE_AUTH: Path to the credentials file.

    TEMPO: Time in seconds that each connection lasts before rotating (default 360).

## ⚠️ Security Warning

This script modifies the system firewall (UFW) and kernel parameters at runtime. Use it at your own risk. Please review and understand the code before running it in a production environment.

## License

This script is protected by License MIT

Made by @D4vKry for all.
