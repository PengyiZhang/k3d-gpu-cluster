#!/bin/sh
/load_image.sh & 
exec /bin/k3s agent
