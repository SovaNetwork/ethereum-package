shared_utils = import_module("../shared_utils/shared_utils.star")
input_parser = import_module("../package_io/input_parser.star")
constants = import_module("../package_io/constants.star")
node_metrics = import_module("../node_metrics_info.star")

# Constants for the sentinel service
SENTINEL_PORT = 50051
METRICS_PORT = 9102
METRICS_PATH = "/metrics"

def new_sentinel_launcher(bitcoin_rpc_url=None, bitcoin_rpc_user=None, bitcoin_rpc_pass=None, confirmation_threshold=6, revert_threshold=18):
    """Creates a new sentinel launcher configuration
    
    Args:
        bitcoin_rpc_url: URL for the Bitcoin RPC service
        bitcoin_rpc_user: Username for Bitcoin RPC authentication
        bitcoin_rpc_pass: Password for Bitcoin RPC authentication
        confirmation_threshold: Number of confirmations required to unlock a slot
        revert_threshold: Number of blocks after which a locked slot will revert
    
    Returns:
        A struct containing the sentinel launch configuration
    """
    return struct(
        bitcoin_rpc_url=bitcoin_rpc_url,
        bitcoin_rpc_user=bitcoin_rpc_user,
        bitcoin_rpc_pass=bitcoin_rpc_pass,
        confirmation_threshold=confirmation_threshold,
        revert_threshold=revert_threshold,
    )

def launch(
    plan,
    launcher,
    service_name,
    bitcoin_confirmation_threshold=None,
    bitcoin_revert_threshold=None,
    min_cpu=100,
    max_cpu=500,
    min_mem=128,
    max_mem=512,
    persistent=False,
    tolerations=[],
    node_selectors={},
    docker_cache_params=None,
):
    """Launches a Sova Sentinel service
    
    Args:
        plan: The Kurtosis execution plan
        launcher: The sentinel launcher configuration
        service_name: Name for the sentinel service
        bitcoin_confirmation_threshold: Number of confirmations required to unlock a slot
        bitcoin_revert_threshold: Number of blocks after which a locked slot will revert
        min_cpu: Minimum CPU allocation (millicores)
        max_cpu: Maximum CPU allocation (millicores)
        min_mem: Minimum memory allocation (MB)
        max_mem: Maximum memory allocation (MB)
        persistent: Whether to use persistent storage
        tolerations: Kubernetes tolerations for the service
        node_selectors: Kubernetes node selectors for the service
        docker_cache_params: Docker cache parameters
    
    Returns:
        A struct containing information about the launched sentinel service
    """
    image = "ghcr.io/sovanetwork/sova-sentinel:v0.1.0"
    
    # Apply docker cache if needed
    if docker_cache_params and docker_cache_params.enabled and constants.CONTAINER_REGISTRY.ghcr in image:
        image = (
            docker_cache_params.url
            + docker_cache_params.github_prefix
            + "/".join(image.split("/")[1:])
        )

    # Set up port mapping
    used_ports = {
        "grpc": PortSpec(number=SENTINEL_PORT, transport_protocol="TCP"),
        # "metrics": PortSpec(number=METRICS_PORT, transport_protocol="TCP"),
    }

    # Get confirmation and revert thresholds from launcher if not explicitly provided
    confirmation_threshold = bitcoin_confirmation_threshold or launcher.confirmation_threshold
    revert_threshold = bitcoin_revert_threshold or launcher.revert_threshold

    # Set up environment variables
    env_vars = {
        "SOVA_SENTINEL_HOST": "0.0.0.0",
        "SOVA_SENTINEL_PORT": str(SENTINEL_PORT),
        "SOVA_SENTINEL_DB_PATH": "/app/data/slot_locks.db",
        "BITCOIN_CONFIRMATION_THRESHOLD": str(confirmation_threshold),
        "BITCOIN_REVERT_THRESHOLD": str(revert_threshold),
        "RUST_LOG": "debug",
    }
    
    if launcher.bitcoin_rpc_url:
        env_vars["BITCOIN_RPC_URL"] = launcher.bitcoin_rpc_url
    if launcher.bitcoin_rpc_user:
        env_vars["BITCOIN_RPC_USER"] = launcher.bitcoin_rpc_user
    if launcher.bitcoin_rpc_pass:
        env_vars["BITCOIN_RPC_PASS"] = launcher.bitcoin_rpc_pass
    
    # File mounts
    files = {}
    if persistent:
        files["/app/data"] = Directory(
            persistent_key="sentinel-data-{0}".format(service_name),
            size=1000,  # 1GB of storage
        )

    # Configure the service
    config = ServiceConfig(
        image=image,
        ports=used_ports,
        env_vars=env_vars,
        files=files,
        min_cpu=min_cpu,
        max_cpu=max_cpu,
        min_memory=min_mem,
        max_memory=max_mem,
        labels=shared_utils.label_maker(
            client="sova-sentinel",
            client_type="sentinel",
            image=image[-constants.MAX_LABEL_LENGTH:],
            connected_client="",
            extra_labels={},
            supernode=False,
        ),
        tolerations=tolerations,
        node_selectors=node_selectors,
    )

    # Launch the service
    service = plan.add_service(service_name, config)
    
    # Create metrics info
    metric_url = "{0}:{1}".format(service.ip_address, METRICS_PORT)
    metrics_info = node_metrics.new_node_metrics_info(
        service_name, METRICS_PATH, metric_url
    )

    return struct(
        service_name=service_name,
        ip_address=service.ip_address,
        grpc_port=SENTINEL_PORT,
        metrics_info=metrics_info,
        grpc_url="http://{0}:{1}".format(service.ip_address, SENTINEL_PORT),
    )