data "aws_region" "current" {
  # Fetch the current AWS region for use in CloudWatch dashboard widgets
}

# Store the Agent Config in SSM Parameter Store
resource "aws_ssm_parameter" "cloudwatch_agent_config" {
  name        = "AmazonCloudWatch-ec2-config"
  type        = "String"
  value       = file("${path.module}/agent-config.json")
  description = "CloudWatch Agent configuration for EC2 instances"
}

# SNS Topic for CloudWatch Alarms
resource "aws_sns_topic" "cloudwatch_alarms_topic" {
  name = "cloudwatch-alarms-topic-${var.environment_name}"
  tags = var.tags
}

# Email Subscription for the SNS Topic
resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.cloudwatch_alarms_topic.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# EC2 Status Check Failed 
# Triggers if either system or instance status checks fail for 2 consecutive minutes
resource "aws_cloudwatch_metric_alarm" "ec2_status_check" {
  alarm_name          = "ec2-status-check"
  alarm_description   = "EC2 instance failed status check (hardware or network issue)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_actions       = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions          = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  tags                = var.tags

  dimensions = {
    InstanceId = aws_instance.private_ec2.id # Pass this variable from root/module caller
  }
}

# High CPU Utilization 
# Triggers if CPU > 80% for 3 consecutive 5-minute periods
resource "aws_cloudwatch_metric_alarm" "ec2_high_cpu" {
  alarm_name          = "ec2-high-cpu"
  alarm_description   = "EC2 CPU utilization exceeds 80%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions          = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  tags                = var.tags

  dimensions = {
    InstanceId = aws_instance.private_ec2.id
  }
}

# High Memory Utilization
# Triggers if mem_used_percent > 90% for 2 consecutive 1-minute periods
# Validates that the CloudWatch Agent is running and sending data to 'CWAgent' namespace
resource "aws_cloudwatch_metric_alarm" "ec2_high_memory" {
  alarm_name          = "ec2-high-memory"
  alarm_description   = "EC2 Memory utilization exceeds 90% (Agent validation)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 60
  statistic           = "Average"
  threshold           = 90
  alarm_actions       = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions          = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  tags                = var.tags

  # Treat missing data as breaching to catch agent failures
  treat_missing_data = "breaching"

  dimensions = {
    InstanceId = aws_instance.private_ec2.id
  }
}

#disk utilization
#triggers if disk_used_percent > 90% for 2 consecutive 1-minute periods
#validates that the CloudWatch Agent is running and sending data to 'CWAgent' namespace
resource "aws_cloudwatch_metric_alarm" "ec2_high_disk" {
  alarm_name          = "ec2-high-disk"
  alarm_description   = "EC2 Disk utilization exceeds 90% (Agent validation)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 60
  statistic           = "Average"
  threshold           = 90
  alarm_actions       = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions          = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  tags                = var.tags

  # Treat missing data as breaching to catch agent failures
  treat_missing_data = "breaching"

  dimensions = {
    InstanceId = aws_instance.private_ec2.id
    path       = "/"
    fstype     = "xfs"
  }
  
}

# ALB Unhealthy Host Count
# Triggers immediately if ANY target in the group is unhealthy
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "alb-unhealthy-hosts"
  alarm_description   = "ALB Target Group has unhealthy hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_actions       = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions          = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  tags                = var.tags

  dimensions = {
    LoadBalancer = module.vpc.alb_arn_suffix          # Pass alb_arn_suffix (e.g., "app/my-alb/12345")
    TargetGroup  = module.vpc.target_group_arn_suffix # Pass target_group_arn_suffix
  }
}

# ALB 5xx Error Count
# Triggers if 5xx errors exceed threshold for 2 consecutive 1-minute periods
resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
  alarm_name          = "alb-5xx-errors"
  alarm_description   = "ALB 5xx error count exceeds threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_actions       = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions          = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  tags                = var.tags

  dimensions = {
    LoadBalancer = module.vpc.alb_arn_suffix
  }
  
}

#Cloudwatch Dashboard for EC2 and ALB Monitoring
resource "aws_cloudwatch_dashboard" "omnifood_main" {
  dashboard_name = "Omnifood-Main-Dashboard-${var.environment_name}"

  dashboard_body = jsonencode({
    widgets = [
      # --- Header ---
      {
        type = "text"
        x    = 0
        y    = 0
        width = 24
        height = 1
        properties = {
          markdown = "# Omnifood Infrastructure Overview\nReal-time monitoring using "
        }
      },

      # Alarm Status Widget
      {
        type = "alarm"
        x    = 0
        y    = 1
        width = 24
        height = 2
        properties = {
          title = "Current Alarm Status"
          alarms = [
            aws_cloudwatch_metric_alarm.ec2_status_check.arn,
            aws_cloudwatch_metric_alarm.ec2_high_cpu.arn,
            aws_cloudwatch_metric_alarm.alb_unhealthy_hosts.arn,
            aws_cloudwatch_metric_alarm.ec2_high_memory.arn,
            aws_cloudwatch_metric_alarm.ec2_high_disk.arn
          ]
        }
      },

      # Widget 1: EC2 Health
      {
        type = "metric"
        x    = 0
        y    = 3
        width = 12
        height = 6
        properties = {
          title = "EC2 Health: CPU & Status Checks"
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.private_ec2.id, { stat = "Average", label = "CPU %" }],
            ["AWS/EC2", "StatusCheckFailed", "InstanceId", aws_instance.private_ec2.id, { stat = "Maximum", label = "Status Failures", color = "#d62728" }],
            ["CWAgent", "disk_used_percent", "InstanceId", aws_instance.private_ec2.id, "path", "/", "fstype", "xfs", { stat = "Average", label = "Disk Usage %" }],
          ]
          period = 60
          stat   = "Average"
          region = data.aws_region.current.region
          view   = "timeSeries"
          yAxis = {
            left = {
              min = 0
              max = 100
              label = "Percent"
            }
          }
        }
      },

      # Widget 2: Network & Disk I/O
      {
        type = "metric"
        x    = 12
        y    = 3
        width = 12
        height = 6
        properties = {
          title = "EC2 I/O: Network & Disk Operations"
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", aws_instance.private_ec2.id, { stat = "Average", label = "Net In (Bytes)", color = "#1f77b4" }],
            ["AWS/EC2", "NetworkOut", "InstanceId", aws_instance.private_ec2.id, { stat = "Average", label = "Net Out (Bytes)", color = "#2ca02c" }],
            ["AWS/EC2", "DiskReadOps", "InstanceId", aws_instance.private_ec2.id, { stat = "Average", label = "Disk Read Ops", color = "#ff7f0e" }],
            ["AWS/EC2", "DiskWriteOps", "InstanceId", aws_instance.private_ec2.id, { stat = "Average", label = "Disk Write Ops", color = "#d62728" }]
          ]
          period = 60
          stat   = "Average"
          region = data.aws_region.current.region
          view   = "timeSeries"
        }
      },

      # Section Header: Load Balancer
      {
        type = "text"
        x    = 0
        y    = 9
        width = 24
        height = 1
        properties = {
          markdown = "### Application Load Balancer Performance"
        }
      },

      # Widget 3: ALB Traffic
      {
        type = "metric"
        x    = 0
        y    = 10
        width = 12
        height = 6
        properties = {
          title = "ALB Traffic: Requests & Latency"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", module.vpc.alb_arn_suffix, { stat = "Sum", label = "Requests" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", module.vpc.alb_arn_suffix, { stat = "Average", label = "Avg Latency (s)" }]
          ]
          period = 60
          stat   = "Sum"
          region = data.aws_region.current.region
          view   = "timeSeries"
        }
      },

      # Widget 4: ALB Health
      {
        type = "metric"
        x    = 12
        y    = 10
        width = 12
        height = 6
        properties = {
          title = "ALB Health: Host Count"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", module.vpc.alb_arn_suffix, "TargetGroup", module.vpc.target_group_arn_suffix, { stat = "Average", label = "Healthy" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", module.vpc.alb_arn_suffix, "TargetGroup", module.vpc.target_group_arn_suffix, { stat = "Maximum", label = "Unhealthy", color = "#d62728" }]
          ]
          period = 60
          stat   = "Average"
          region = data.aws_region.current.region
          view   = "timeSeries"
          yAxis = {
            left = {
              min = 0
              label = "Hosts"
            }
          }
        }
      },

      # Widget 5: Errors 
      {
        type = "metric"
        x    = 0
        y    = 16
        width = 24
        height = 6
        properties = {
          title = "Error Rates: Target & ELB 5xx"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", module.vpc.alb_arn_suffix, { stat = "Sum", label = "Target 5xx" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", module.vpc.alb_arn_suffix, { stat = "Sum", label = "ELB 5xx", color = "#ff7f0e" }]
          ]
          period = 60
          stat   = "Sum"
          region = data.aws_region.current.region
          view   = "timeSeries"
        }
      }
    ]
  })
}   