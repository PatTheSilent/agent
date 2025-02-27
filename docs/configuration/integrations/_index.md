+++
title = "integrations_config"
weight = 500
+++

# integrations_config

The `integrations_config` block configures how the Agent runs integrations that
scrape and send metrics without needing to run specific Prometheus exporters or
manually write `scrape_configs`:

```yaml
# Controls the Agent integration
agent:
  # Enables the Agent integration, allowing the Agent to automatically
  # collect and send metrics about itself.
  [enabled: <boolean> | default = false]

  # Automatically collect metrics from this integration. If disabled,
  # the agent integration will be run but not scraped and thus not
  # remote_written. Metrics for the integration will be exposed at
  # /integrations/agent/metrics and can be scraped by an external process.
  [scrape_integration: <boolean> | default = <integrations_config.scrape_integrations>]

  # How often should the metrics be collected? Defaults to
  # prometheus.global.scrape_interval.
  [scrape_interval: <duration> | default = <global_config.scrape_interval>]

  # The timtout before considering the scrape a failure. Defaults to
  # prometheus.global.scrape_timeout.
  [scrape_timeout: <duration> | default = <global_config.scrape_timeout>]

  # How frequent to truncate the WAL for this integration.
  [wal_truncate_frequency: <duration> | default = "60m"]

  # Allows for relabeling labels on the target.
  relabel_configs:
    [- <relabel_config> ... ]

  # Relabel metrics coming from the integration, allowing to drop series
  # from the integration that you don't care about.
  metric_relabel_configs:
    [ - <relabel_config> ... ]

# Client TLS Configuration
# Client Cert/Key Values need to be defined if the server is requesting a certificate
#  (Client Auth Type = RequireAndVerifyClientCert || RequireAnyClientCert).
http_tls_config: <tls_config>

# Controls the node_exporter integration
node_exporter: <node_exporter_config>

# Controls the process_exporter integration
process_exporter: <process_exporter_config>

# Controls the mysqld_exporter integration
mysqld_exporter: <mysqld_exporter_config>

# Controls the redis_exporter integration
redis_exporter: <redis_exporter_config>

# Controls the dnsmasq_exporter integration
dnsmasq_exporter: <dnsmasq_exporter_config>

# Controls the elasticsearch_expoter integration
elasticsearch_expoter: <elasticsearch_expoter_config>

# Controls the memcached_exporter integration
memcached_exporter: <memcached_exporter_config>

# Controls the postgres_exporter integration
postgres_exporter: <postgres_exporter_config>

# Controls the statsd_exporter integration
statsd_exporter: <statsd_exporter_config>

# Controls the consul_exporter integration
consul_exporter: <consul_exporter_config>

# Controls the windows_exporter integration
windows_exporter: <windows_exporter_config>

# Controls the kafka_exporter integration
kafka_exporter: <kafka_exporter_config>

# Controls the github_exporter integration
github_exporter: <github_exporter_config>

# Automatically collect metrics from enabled integrations. If disabled,
# integrations will be run but not scraped and thus not remote_written. Metrics
# for integrations will be exposed at /integrations/<integration_key>/metrics
# and can be scraped by an external process.
[scrape_integrations: <boolean> | default = true]

# When true, replaces the instance label with the hostname of the machine,
# rather than 127.0.0.1:<server.http_listen_port>. Useful when running multiple
# Agents with the same integrations and uniquely identifying where metrics are
# coming from.
#
# The value for the instance label can be replaced by providing custom
# relabel_configs for an integration. The overwritten instance label will be
# available when relabel_configs run.
[replace_instance_label: <boolean> | default = true]

# When true, adds an agent_hostname label to all samples coming from
# integrations. The value of the agent_hostname label will be the
# value of $HOSTNAME (if available) or the machine's hostname.
#
# DEPRECATED. May be removed in a future version. Rely on
# replace_instance_label instead, since it has better compatability
# with existing dashboards.
[use_hostname_label: <boolean> | default = true]

# Extra labels to add to all samples coming from integrations.
labels:
  { <string>: <string> }

# The period to wait before restarting an integration that exits with an
# error.
[integration_restart_backoff: <duration> | default = "5s"]

# A list of remote_write targets. Defaults to global_config.remote_write.
# If provided, overrides the global defaults.
prometheus_remote_write:
  - [<remote_write>]
```
