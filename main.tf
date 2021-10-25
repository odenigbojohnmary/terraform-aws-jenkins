# Elastic Beanstalk Application
module "elastic_beanstalk_application" {
  source      = "./modules/elastic_beanstalk_application"
  namespace   = var.namespace
  name        = var.name
  stage       = var.stage
  description = var.description
  delimiter   = var.delimiter
  attributes  = compact(concat(var.attributes, ["app"]))
  tags        = var.tags
}

# Elastic Beanstalk Environment
module "elastic_beanstalk_environment" {
  source                             = "./modules/elastic_beanstalk_environment"
  namespace                          = var.namespace
  name                               = var.name
  stage                              = var.stage
  delimiter                          = var.delimiter
  attributes                         = compact(concat(var.attributes, ["env"]))
  tags                               = var.tags
  region                             = var.region
  dns_zone_id                        = var.dns_zone_id
  domain_name                        = var.domain_name
  elastic_beanstalk_application_name = module.elastic_beanstalk_application.elastic_beanstalk_application_name
  instance_type                      = var.master_instance_type

  s3logs                       = var.s3logs
  tier                         = "WebServer"
  environment_type             = var.environment_type
  loadbalancer_type            = var.loadbalancer_type
  loadbalancer_certificate_arn = var.loadbalancer_certificate_arn
  availability_zone_selector   = var.availability_zone_selector
  rolling_update_type          = var.rolling_update_type

  # Set `min` and `max` number of running EC2 instances to `1` since we want only one Jenkins master running at any time
  autoscale_min = 1
  autoscale_max = 1

  # Since we set `autoscale_min = autoscale_max`, we need to set `updating_min_in_service` to 0 for the AutoScaling Group to work.
  # Elastic Beanstalk will terminate the master instance and replace it with a new one in case of any issues with it.
  # It's OK since we store all Jenkins state (settings, jobs, etc.) on the EFS.
  # If the instance gets replaced or rebooted, Jenkins will find all the data on the EFS after restart.
  updating_min_in_service = 0

  updating_max_batch = 1

  healthcheck_url         = var.healthcheck_url
  vpc_id                  = var.vpc_id
  loadbalancer_subnets    = var.loadbalancer_subnets
  application_subnets     = var.application_subnets
  allowed_security_groups = var.allowed_security_groups
  keypair                 = var.ssh_key_pair
  solution_stack_name     = var.solution_stack_name
  force_destroy           = var.loadbalancer_logs_bucket_force_destroy

  # Provide EFS DNS name to EB in the `EFS_HOST` ENV var. EC2 instance will mount to the EFS filesystem and use it to store Jenkins state
  # Add slaves Security Group `JENKINS_SLAVE_SECURITY_GROUPS` (comma-separated if more than one). Will be used by Jenkins to init the EC2 plugin to launch slaves inside the Security Group
  env_vars = merge(
    {
      "EFS_HOST"                      = var.use_efs_ip_address ? module.efs.mount_target_ips[0] : module.efs.dns_name
      "USE_EFS_IP"                    = var.use_efs_ip_address
      "JENKINS_SLAVE_SECURITY_GROUPS" = aws_security_group.slaves.id
    },
    var.env_vars
  )
}

# Elastic Container Registry Docker Repository
module "ecr" {
  source     = "./modules/ecr"
  namespace  = var.namespace
  name       = var.name
  stage      = var.stage
  delimiter  = var.delimiter
  attributes = var.attributes
  tags       = var.tags
}

# EFS to store Jenkins state (settings, jobs, etc.)
module "efs" {
  source     = "./modules/efs"
  namespace  = var.namespace
  name       = var.name
  stage      = var.stage
  delimiter  = var.delimiter
  attributes = compact(concat(var.attributes, ["efs"]))
  tags       = var.tags
  region     = var.region
  vpc_id     = var.vpc_id
  subnets    = var.application_subnets
  zone_id    = var.dns_zone_id

  # EC2 instances (from `elastic_beanstalk_environment`) are allowed to connect to the EFS
  security_groups = [module.elastic_beanstalk_environment.security_group_id]
}

# EFS backup
module "efs_backup" {
  source             = "./modules/efs_backup"
  namespace          = var.namespace
  stage              = var.stage
  name               = var.name
  attributes         = compact(concat(var.attributes, ["efs"]))
  tags               = var.tags
  delimiter          = var.delimiter
  backup_resources   = [module.efs.arn]
  schedule           = var.efs_backup_schedule
  start_window       = var.efs_backup_start_window
  completion_window  = var.efs_backup_completion_window
  cold_storage_after = var.efs_backup_cold_storage_after
  delete_after       = var.efs_backup_delete_after
}

# CodePipeline/CodeBuild to build Jenkins Docker image, store it to a ECR repo, and deploy it to Elastic Beanstalk running Docker stack
module "cicd" {
  source                             = "./modules/cicd"
  namespace                          = var.namespace
  stage                              = var.stage
  name                               = var.name
  delimiter                          = var.delimiter
  attributes                         = compact(concat(var.attributes, ["cicd"]))
  tags                               = var.tags
  elastic_beanstalk_application_name = module.elastic_beanstalk_application.elastic_beanstalk_application_name
  elastic_beanstalk_environment_name = module.elastic_beanstalk_environment.name
  enabled                            = true
  github_oauth_token                 = var.github_oauth_token
  repo_owner                         = var.github_organization
  repo_name                          = var.github_repo_name
  branch                             = var.github_branch
  build_image                        = var.build_image
  build_compute_type                 = var.build_compute_type
  privileged_mode                    = true
  region                             = var.region
  aws_account_id                     = var.aws_account_id
  image_repo_name                    = module.ecr.repository_name
  image_tag                          = var.image_tag
  poll_source_changes                = true
  force_destroy                      = var.cicd_bucket_force_destroy
}

# Label for EC2 slaves
module "label_slaves" {
  source     = "../labels-null"
  namespace  = var.namespace
  name       = var.name
  stage      = var.stage
  delimiter  = var.delimiter
  attributes = compact(concat(var.attributes, ["slaves"]))
  tags       = var.tags
}

# Security Group for EC2 slaves
resource "aws_security_group" "slaves" {
  name        = module.label_slaves.id
  description = "Security Group for Jenkins EC2 slaves"
  vpc_id      = var.vpc_id

  # Allow the provided Security Groups to connect to Jenkins slave instances
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = -1
    security_groups = var.allowed_security_groups
  }

  # Allow Jenkins master instance to communicate with Jenkins slave instances on SSH port 22
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [module.elastic_beanstalk_environment.security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = module.label_slaves.tags
}

# Policy document with permissions to launch new EC2 instances
# https://wiki.jenkins.io/display/JENKINS/Amazon+EC2+Plugin
data "aws_iam_policy_document" "slaves" {
  statement {
    sid = "AllowLaunchingEC2Instances"

    actions = [
      "ec2:DescribeSpotInstanceRequests",
      "ec2:CancelSpotInstanceRequests",
      "ec2:GetConsoleOutput",
      "ec2:RequestSpotInstances",
      "ec2:RunInstances",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:DescribeInstances",
      "ec2:DescribeKeyPairs",
      "ec2:DescribeRegions",
      "ec2:DescribeImages",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "iam:ListInstanceProfilesForRole",
      "iam:PassRole",
      "ec2:GetPasswordData"
    ]

    resources = ["*"]
    effect    = "Allow"
  }
}

# Policy for the EB EC2 instance profile to allow launching Jenkins slaves
resource "aws_iam_policy" "slaves" {
  name        = module.label_slaves.id
  path        = "/"
  description = "Policy for EC2 instance profile to allow launching Jenkins slaves"
  policy      = data.aws_iam_policy_document.slaves.json
}

# Attach Policy to the EC2 instance profile to allow Jenkins master to launch and control slave EC2 instances
resource "aws_iam_role_policy_attachment" "slaves" {
  role       = module.elastic_beanstalk_environment.ec2_instance_profile_role_name
  policy_arn = aws_iam_policy.slaves.arn
}



# Label for EC2 packer
module "label_packer" {
  source     = "../labels-null"
  namespace  = var.namespace
  name       = var.name
  stage      = var.stage
  delimiter  = var.delimiter
  attributes = compact(concat(var.attributes, ["packer"]))
  tags       = var.tags
}

# Security Group for EC2 packer
resource "aws_security_group" "packer" {
  name        = module.label_packer.id
  description = "Security Group for Jenkins EC2 packer"
  vpc_id      = var.vpc_id

  # Allow the provided Security Groups to connect to Jenkins packer instances
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = -1
    security_groups = var.allowed_security_groups
  }

  # Allow Jenkins master instance to communicate with Jenkins packer instances on SSH port 22
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.slaves.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = module.label_packer.tags
}

data "aws_iam_policy_document" "packer" {
  statement {
    sid = "AllowLaunchingEC2Instances"

    actions = [
      "ec2:AttachVolume",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CopyImage",
      "ec2:CreateImage",
      "ec2:CreateKeypair",
      "ec2:CreateSecurityGroup",
      "ec2:CreateSnapshot",
      "ec2:CreateTags",
      "ec2:CreateVolume",
      "ec2:DeleteKeyPair",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteSnapshot",
      "ec2:DeleteVolume",
      "ec2:DeregisterImage",
      "ec2:DescribeImageAttribute",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeRegions",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSnapshots",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeVolumes",
      "ec2:DetachVolume",
      "ec2:GetPasswordData",
      "ec2:ModifyImageAttribute",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifySnapshotAttribute",
      "ec2:RegisterImage",
      "ec2:RunInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
      "sts:AssumeRole"
    ]

    resources = ["*"]
    effect    = "Allow"
  }
}

# Policy for the EB EC2 instance profile to allow launching Jenkins packer
resource "aws_iam_policy" "packer" {
  name        = module.label_packer.id
  path        = "/"
  description = "Policy for EC2 instance profile to allow launching Jenkins packer"
  policy      = data.aws_iam_policy_document.packer.json
}

resource "aws_iam_instance_profile" "packer" {
  name = module.label_packer.id
  role = module.label_packer.id
}

resource "aws_iam_role_policy" "default" {
  name   = module.label_packer.id
  role   = aws_iam_role.packer.id
  policy = data.aws_iam_policy_document.packer.json
}

resource "aws_iam_role" "packer" {
  name = module.label_packer.id

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

  tags = {
    tag-key = "tag-value"
  }
}
