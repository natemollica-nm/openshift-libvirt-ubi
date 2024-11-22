operator = "write"
agent_prefix "" {
  policy = "read"
}
partition_prefix "" {
  namespace_prefix "" {
    acl = "write"
    service_prefix "" {
      policy = "write"
    }
  }
}