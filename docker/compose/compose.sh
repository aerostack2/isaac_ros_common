#!/bin/bash

if [[ $PLATFORM == "aarch64" ]]; then
    echo "aarch64 architecture detected"
    cat docker-compose-aarch64.txt > docker-compose.yml
else
    echo "x86_64 architecture detected"
    cat docker-compose-x86_64.txt > docker-compose.yml
fi

docker compose up -d

docker exec -it arquimea_container /bin/bash