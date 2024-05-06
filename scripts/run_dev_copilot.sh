#!/bin/bash
#
# Copyright (c) 2021-2022, NVIDIA CORPORATION.  All rights reserved.
#
# NVIDIA CORPORATION and its licensors retain all intellectual property
# and proprietary rights in and to this software, related documentation
# and any modifications thereto.  Any use, reproduction, disclosure or
# distribution of this software and related documentation without an express
# license agreement from NVIDIA CORPORATION is strictly prohibited.

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source $ROOT/utils/print_color.sh

if [[ -f "${ROOT}/.isaac_ros_common-config" ]]; then
    . "${ROOT}/.isaac_ros_common-config"
fi

PLATFORM="$(uname -m)"

BASE_NAME="isaac_ros_dev-$PLATFORM"
CONTAINER_NAME="as2_copilot"

# Remove any exited containers.
if [ "$(docker ps -a --quiet --filter status=exited --filter name=$CONTAINER_NAME)" ]; then
    docker rm $CONTAINER_NAME > /dev/null
fi

# Re-use existing container.
if [ "$(docker ps -a --quiet --filter status=running --filter name=$CONTAINER_NAME)" ]; then
    print_info "Attaching to running container: $CONTAINER_NAME"
    docker exec -i -t --workdir /root $CONTAINER_NAME /bin/bash $@
    exit 0
fi

print_info "Env variables relevant to build the docker image imported from ISAAC_ROS_COMMON_CONFIG: "
print_info "NO_BUILD_DOCKER : $NO_BUILD_DOCKER"
print_info "PROJECT_DIR : $PROJECT_DIR"
print_info "PROJECT_NAME: $PROJECT_NAME"
print_info "AS2_WS: $AS2_WS"
print_info "PSDK_WS: $PSDK_WS"

function usage() {
    print_info "Usage: run_dev.sh" {isaac_ros_dev directory path OPTIONAL}
    print_info "Copyright (c) 2021-2022, NVIDIA CORPORATION."
}

# Read and parse config file if exists
#
# CONFIG_IMAGE_KEY (string, can be empty)


read -p "Run docker? (y/n): " confirm 

if [[ $confirm != "y" ]]; then
  echo "Aborting building" && exit 1
fi

ISAAC_ROS_DEV_DIR="$1"
if [[ -z "$ISAAC_ROS_DEV_DIR" ]]; then
    ISAAC_ROS_DEV_DIR_DEFAULTS=("$HOME/workspaces/isaac_ros-dev" "/workspaces/isaac_ros-dev")
    for ISAAC_ROS_DEV_DIR in "${ISAAC_ROS_DEV_DIR_DEFAULTS[@]}"
    do
        if [[ -d "$ISAAC_ROS_DEV_DIR" ]]; then
            break
        fi
    done

    if [[ ! -d "$ISAAC_ROS_DEV_DIR" ]]; then
        ISAAC_ROS_DEV_DIR=$(realpath "$ROOT/../")
    fi
    print_warning "isaac_ros_dev not specified, assuming $ISAAC_ROS_DEV_DIR"
else
    if [[ ! -d "$ISAAC_ROS_DEV_DIR" ]]; then
        print_error "Specified isaac_ros_dev does not exist: $ISAAC_ROS_DEV_DIR"
        exit 1
    fi
    shift 1
fi

ON_EXIT=()
function cleanup {
    for command in "${ON_EXIT[@]}"
    do
        $command
    done
}
trap cleanup EXIT

pushd . >/dev/null
cd $ROOT
ON_EXIT+=("popd")

# Prevent running as root.
if [[ $(id -u) -eq 0 ]]; then
    print_error "This script cannot be executed with root privileges."
    print_error "Please re-run without sudo and follow instructions to configure docker for non-root user if needed."
    exit 1
fi

# Check if user can run docker without root.
RE="\<docker\>"
if [[ ! $(groups $USER) =~ $RE ]]; then
    print_error "User |$USER| is not a member of the 'docker' group and cannot run docker commands without sudo."
    print_error "Run 'sudo usermod -aG docker \$USER && newgrp docker' to add user to 'docker' group, then re-run this script."
    print_error "See: https://docs.docker.com/engine/install/linux-postinstall/"
    exit 1
fi

# Check if able to run docker commands.
if [[ -z "$(docker ps)" ]] ;  then
    print_error "Unable to run docker commands. If you have recently added |$USER| to 'docker' group, you may need to log out and log back in for it to take effect."
    print_error "Otherwise, please check your Docker installation."
    exit 1
fi

# Check if git-lfs is installed.
git lfs &>/dev/null
if [[ $? -ne 0 ]] ; then
    print_error "git-lfs is not insalled. Please make sure git-lfs is installed before you clone the repo."
    exit 1
fi

# Check if all LFS files are in place in the repository where this script is running from.
cd $ROOT
git rev-parse &>/dev/null
if [[ $? -eq 0 ]]; then
    LFS_FILES_STATUS=$(cd $ISAAC_ROS_DEV_DIR && git lfs ls-files | cut -d ' ' -f2)
    for (( i=0; i<${#LFS_FILES_STATUS}; i++ )); do
        f="${LFS_FILES_STATUS:$i:1}"
        if [[ "$f" == "-" ]]; then
            print_error "LFS files are missing. Please re-clone the repo after installing git-lfs."
            exit 1
        fi
    done
fi



# check if additional configs for the platform exist
ARCH_CONFIG=""
DOCKERFILE_PATH=""
for dir in "$(dirname $ROOT)/${CONFIG_DOCKER_SEARCH_DIRS[@]}"
do
    DOCKERFILE_PATH="$dir/Dockerfile.config_${PLATFORM}"
    if [[ -f "$DOCKERFILE_PATH" ]]; then
        break
    fi
done
if [[ ! -f "$DOCKERFILE_PATH" ]]; then
    print_info "No especific Dockerfile config found for platform: $PLATFORM"
else
    print_info "Using Dockerfile config: $DOCKERFILE_PATH"
    ARCH_CONFIG=.config_${PLATFORM}
fi

# Build image
IMAGE_KEY=ros2_humble
if [[ ! -z "${CONFIG_IMAGE_KEY}" ]]; then
    IMAGE_KEY=$CONFIG_IMAGE_KEY
fi

USER_CONFIG=".user"
if [[ ! -z "${IMAGE_KEY}" ]]; then
    BASE_IMAGE_KEY=$PLATFORM.$IMAGE_KEY

    # If the configured key does not have .user, append it last
    if [[ $IMAGE_KEY != *".user"* ]]; then
        BASE_IMAGE_KEY=$BASE_IMAGE_KEY$USER_CONFIG
    fi
    #   BASE_IMAGE_KEY=$BASE_IMAGE_KEY$USER_CONFIG
    # fi


    if [[ ! -z "$ARCH_CONFIG" ]]; then
      # use sed for replace $USER_CONFIG with $ARCH_CONFIG in the base image key
      # echo "BASE_IMAGE_KEY: $BASE_IMAGE_KEY"
      SED_EXPRESSION="s/$USER_CONFIG/$USER_CONFIG$ARCH_CONFIG/"
      # echo "SED_EXPRESSION: $SED_EXPRESSION"
      BASE_IMAGE_KEY=$(echo $BASE_IMAGE_KEY | sed ${SED_EXPRESSION})
    fi

fi

# Check for extra architecture specific image with dependencies

# echo "DOCKER SEARCH DIRS: ${CONFIG_DOCKER_SEARCH_DIRS[@]}"
# find a Dockerfile.$ARCH_config file in the search directories

print_info "Using base image key: $BASE_IMAGE_KEY"
# exit 1


print_info "Building $BASE_IMAGE_KEY base as image: $BASE_NAME using key $BASE_IMAGE_KEY"
if [[ $NO_BUILD_DOCKER -ne 1 ]]; then
$ROOT/build_base_image.sh $BASE_IMAGE_KEY $BASE_NAME '' '' ''
else
print_info "NO BUILD ENABLE" 
fi

if [ $? -ne 0 ]; then
    print_error "Failed to build base image: $BASE_NAME, aborting."
    exit 1
fi

# Map host's display socket to docker
DOCKER_ARGS+=("-v /tmp/.X11-unix:/tmp/.X11-unix")
DOCKER_ARGS+=("-v $HOME/.Xauthority:/home/admin/.Xauthority:rw")
DOCKER_ARGS+=("-e DISPLAY")
DOCKER_ARGS+=("-e NVIDIA_VISIBLE_DEVICES=all")
DOCKER_ARGS+=("-e NVIDIA_DRIVER_CAPABILITIES=all")
DOCKER_ARGS+=("-e FASTRTPS_DEFAULT_PROFILES_FILE=/usr/local/share/middleware_profiles/rtps_udp_profile.xml")
DOCKER_ARGS+=("-e ROS_DOMAIN_ID")
DOCKER_ARGS+=("-e USER")

# if minerva_training not present, clone it
if [ -d ~/Documents/minerva_training ]; then
    print_info "minerva_training already cloned. Pulling..."
    cd ~/Documents/minerva_training
    git pull
    cd -
else
    print_info "Cloning minerva_training"
    git clone git@github.com:cvar-vision-dl/minerva_training.git ~/Documents/minerva_training
fi
# if custom ultralytics not present, clone it
if [ -d ~/Documents/ultralytics ]; then
    print_info "Ultralytics already cloned. Pulling..."
    cd ~/Documents/ultralytics
    git pull
    cd -
else
    print_info "Cloning Ultralytics"
    git clone -b 5_channels git@github.com:cvar-vision-dl/ultralytics.git ~/Documents/ultralytics
fi

# mount ultralytics fork
# DOCKER_ARGS+=("-v ~/Documents/ultralytics:/root/ultralytics")

# if project_copilot not present, clone it

# Check for project dir and mount it
# if [[ -z "${PROJECT_DIR}" ]]; then
#     print_warning "Project directory not specified. Project directory won't be mounted."
# else
#     DOCKER_ARGS+=("-v $PROJECT_DIR:/root/$PROJECT_NAME")
# fi

# Check for Aerostack2 workspace and mount it


# Check for PSDK workspace and mount it


if [[ $PLATFORM == "aarch64" ]]; then
    DOCKER_ARGS+=("-v /usr/bin/tegrastats:/usr/bin/tegrastats")
    DOCKER_ARGS+=("-v /tmp/argus_socket:/tmp/argus_socket")
    DOCKER_ARGS+=("-v /usr/local/cuda-11.4/targets/aarch64-linux/lib/libcusolver.so.11:/usr/local/cuda-11.4/targets/aarch64-linux/lib/libcusolver.so.11")
    DOCKER_ARGS+=("-v /usr/local/cuda-11.4/targets/aarch64-linux/lib/libcusparse.so.11:/usr/local/cuda-11.4/targets/aarch64-linux/lib/libcusparse.so.11")
    DOCKER_ARGS+=("-v /usr/local/cuda-11.4/targets/aarch64-linux/lib/libcurand.so.10:/usr/local/cuda-11.4/targets/aarch64-linux/lib/libcurand.so.10")
    DOCKER_ARGS+=("-v /usr/local/cuda-11.4/targets/aarch64-linux/lib/libcufft.so.10:/usr/local/cuda-11.4/targets/aarch64-linux/lib/libcufft.so.10")
    DOCKER_ARGS+=("-v /usr/local/cuda-11.4/targets/aarch64-linux/lib/libnvToolsExt.so:/usr/local/cuda-11.4/targets/aarch64-linux/lib/libnvToolsExt.so")
    DOCKER_ARGS+=("-v /usr/local/cuda-11.4/targets/aarch64-linux/lib/libcupti.so.11.4:/usr/local/cuda-11.4/targets/aarch64-linux/lib/libcupti.so.11.4")
    DOCKER_ARGS+=("-v /usr/local/cuda-11.4/targets/aarch64-linux/lib/libcudla.so.1:/usr/local/cuda-11.4/targets/aarch64-linux/lib/libcudla.so.1")
    DOCKER_ARGS+=("-v /usr/local/cuda-11.4/targets/aarch64-linux/include/nvToolsExt.h:/usr/local/cuda-11.4/targets/aarch64-linux/include/nvToolsExt.h")
    DOCKER_ARGS+=("-v /usr/lib/aarch64-linux-gnu/tegra:/usr/lib/aarch64-linux-gnu/tegra")
    DOCKER_ARGS+=("-v /usr/src/jetson_multimedia_api:/usr/src/jetson_multimedia_api")
    DOCKER_ARGS+=("-v /opt/nvidia/nsight-systems-cli:/opt/nvidia/nsight-systems-cli")
    DOCKER_ARGS+=("--pid=host")
    DOCKER_ARGS+=("-v /opt/nvidia/vpi2:/opt/nvidia/vpi2")
    DOCKER_ARGS+=("-v /usr/share/vpi2:/usr/share/vpi2")

    # If jtop present, give the container access
    if [[ $(getent group jtop) ]]; then
        DOCKER_ARGS+=("-v /run/jtop.sock:/run/jtop.sock:ro")
        JETSON_STATS_GID="$(getent group jtop | cut -d: -f3)"
        DOCKER_ARGS+=("--group-add $JETSON_STATS_GID")
    fi
fi

# Optionally load custom docker arguments from file
DOCKER_ARGS_FILE="$ROOT/.isaac_ros_dev-dockerargs"
if [[ -f "$DOCKER_ARGS_FILE" ]]; then
    print_info "Using additional Docker run arguments from $DOCKER_ARGS_FILE"
    readarray -t DOCKER_ARGS_FILE_LINES < $DOCKER_ARGS_FILE
    for arg in "${DOCKER_ARGS_FILE_LINES[@]}"; do
        DOCKER_ARGS+=($(eval "echo $arg | envsubst"))
    done
fi

# Run container from image
# print_info "Running $CONTAINER_NAME"
#docker run -it --rm \
#    --privileged \
#    --network host \
#    ${DOCKER_ARGS[@]} \
#    -v $ISAAC_ROS_DEV_DIR:/workspaces/isaac_ros-dev \
#    -v /dev:/dev \
#    -v /etc/localtime:/etc/localtime:ro \
#    --name "$CONTAINER_NAME" \
#    --runtime nvidia \
#    --entrypoint /usr/local/bin/scripts/workspace-entrypoint.sh \
#    --workdir /root \
#    $@ \
#    $BASE_NAME \
#    /bin/bash

# docker run -d --rm \
#     --privileged \
#     --network host \
#     ${DOCKER_ARGS[@]} \
#     -v $ISAAC_ROS_DEV_DIR:/workspaces/isaac_ros-dev \
#     -v /dev:/dev \
#     -v /etc/localtime:/etc/localtime:ro \
#     --name "$CONTAINER_NAME" \
#     --runtime nvidia \
#     --entrypoint /usr/local/bin/scripts/workspace-entrypoint.sh \
#     --workdir /root \
#     $@ \
#     $BASE_NAME \
#     tail -F /dev/null

print_info "Done"