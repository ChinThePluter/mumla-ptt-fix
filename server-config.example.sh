# Server details for install-and-add-server.sh
#
# Copy this file to  server-config.sh  and fill in your values:
#     cp server-config.example.sh server-config.sh
#     # then edit server-config.sh
#
# server-config.sh is gitignored, so your credentials never end up in git.
# This example file is safe to commit (it contains no real credentials).

SERVER_NAME="My Mumble Server"      # label shown in the favourites list
SERVER_HOST="mumble.example.com"    # server address or IP
SERVER_PORT="64738"                 # Mumble default port is 64738
SERVER_USERNAME="myname"            # your Mumble nickname (REQUIRED to connect)
SERVER_PASSWORD=""                  # server password (leave empty if none)
