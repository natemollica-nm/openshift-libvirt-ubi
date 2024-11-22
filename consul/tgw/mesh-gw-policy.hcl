mesh = "write"
peering = "read"
partition_prefix "" {
  peering = "read"
  namespace_prefix "" {
    node_prefix "" {
      policy = "read"
    }
    service_prefix "" {
      policy = "read"
    }
  }
}
namespace "default" {
  service "mesh-gateway" {
    policy = "write"
  }
}