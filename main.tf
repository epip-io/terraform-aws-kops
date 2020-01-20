data "aws_route53_zone" "this" {
  zone_id = var.dns_zone
}

module "label" {
  source      = "git::https://github.com/cloudposse/terraform-null-label.git?ref=tags/0.14.0"
  attributes  = var.attributes
  namespace   = var.namespace
  stage       = var.stage
  delimiter   = var.delimiter
  name        = var.name
  tags        = var.tags
}

locals {
  name = trimsuffix(data.aws_route53_zone.this.name, ".")
  private_subnets = [
    for az in var.azs : {
      name   = format(var.private_subnet_format, module.label.id, az)
      id     = element(var.private_subnets, index(var.azs, az))
      zone   = az
      cidr   = element(var.private_subnets_cidr_blocks, index(var.azs, az))
      type   = "Private"
      egress = element(var.private_subnets_egresses, index(var.azs, az))
      hosts  = pow(2, parseint(split("/", element(var.private_subnets_cidr_blocks, index(var.azs, az)))[1], 10)) - 5
    }
  ]

  utility_subnets = [
    for az in var.azs : {
      name = format(var.utility_subnet_format, module.label.id, az)
      id   = element(var.utility_subnets, index(var.azs, az))
      zone = az
      cidr = element(var.utility_subnets_cidr_blocks, index(var.azs, az))
      type = "Utility"
    }
  ]

  subnets = flatten([local.private_subnets, local.utility_subnets])

  etcd_clusters = [
    for name in tolist(["main", "events"]) : {
      name            = name
      enable_etcd_tls = true
      version         = var.etcd_version
      members = [
        for zone in var.azs : {
          instance_group = format("master-%s", zone)
          name           = format("etcd-%s-%s", name, zone)
        }
      ]
    }
  ]
}

resource "kops_cluster" "cluster" {
  metadata {
    name = local.name
  }

  spec {
    cloud_provider     = "aws"
    kubernetes_version = var.kubernetes_version

    network_cidr        = var.network_cidr
    non_masquerade_cidr = var.non_masquerade_cidr

    kube_dns {
      provider = "CoreDNS"
    }

    kubelet {
      anonymous_auth = "false"
    }

    kube_controller_manager {
      horizontal_pod_autoscaler_use_rest_clients = "true"
    }

    topology {
      dns {
        type = "Private"
      }

      masters = "private"
      nodes   = "private"
    }

    networking {
      calico {
        cross_subnet  = "true"
        major_version = "v3"
      }
    }

    dynamic "subnets" {
      for_each = local.private_subnets

      content {
        name   = subnets.value.name
        id     = subnets.value.id
        zone   = subnets.value.zone
        cidr   = subnets.value.cidr
        type   = subnets.value.type
        egress = subnets.value.egress
      }
    }

    dynamic "subnets" {
      for_each = local.utility_subnets

      content {
        name = subnets.value.name
        id   = subnets.value.id
        zone = subnets.value.zone
        cidr = subnets.value.cidr
        type = subnets.value.type
      }
    }

    dynamic "etcd_clusters" {
      for_each = [
        for name in tolist(["main", "events"]) : {
          name    = name
          version = var.etcd_version
          members = [
            for zone in var.azs : {
              instance_group = format("master-%s", zone)
              name           = format("etcd-%s-%s", name, zone)
            }
          ]
        }
      ]

      content {
        name            = etcd_clusters.value.name
        version         = etcd_clusters.value.version
        enable_etcd_tls = true

        dynamic "etcd_members" {
          for_each = etcd_clusters.value.members

          content {
            name           = etcd_members.value.name
            instance_group = etcd_members.value.instance_group
          }
        }
      }
    }

    kubernetes_api_access = var.admin_cidrs
    ssh_access            = var.admin_cidrs

    master_internal_name = format("api.internal.%s", local.name)
    master_public_name   = format("api.%s", local.name)
  }
}
