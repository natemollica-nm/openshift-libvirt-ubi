partition "default" {
    namespace "default" {
      service_prefix "" {
        policy    = "write"
        intention = "read"
      }
    }
}