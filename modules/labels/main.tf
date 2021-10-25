locals {
  name_original_tags           = join(var.delimiter, compact(concat(tolist([var.name, var.namespace, var.stage]), var.attributes)))
  environment_original_tags    = join(var.delimiter, compact(concat(tolist([var.namespace, var.stage]))))
  name_transformed_tags        = var.convert_case ? lower(local.name_original_tags) : local.name_original_tags
  environment_transformed_tags = var.convert_case ? lower(local.environment_original_tags) : local.environment_original_tags
}

locals {
  id          = var.enabled ? local.name_transformed_tags : ""
  environment = var.enabled ? local.environment_transformed_tags : ""

  name       = var.enabled ? (var.convert_case ? lower(format("%v", var.name)) : format("%v", var.name)) : ""
  namespace  = var.enabled ? (var.convert_case ? lower(format("%v", var.namespace)) : format("%v", var.namespace)) : ""
  stage      = var.enabled ? (var.convert_case ? lower(format("%v", var.stage)) : format("%v", var.stage)) : ""
  delimiter  = var.enabled ? (var.convert_case ? lower(format("%v", var.delimiter)) : format("%v", var.delimiter)) : ""
  attributes = var.enabled ? (var.convert_case ? lower(format("%v", join(var.delimiter, compact(var.attributes)))) : format("%v", join(var.delimiter, compact(var.attributes)))) : ""

  tags = merge(
    {
      "Name"        = local.id
      "Environment" = local.environment
      "Namespace"   = local.namespace
      "Stage"       = local.stage
      "Project"     = local.name
    },
    var.tags
  )
}