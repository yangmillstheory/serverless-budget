variable "bucket" {
  type = "string"
}

variable "key" {
  type = "string"
}

variable "email_prefix" {
  type = "string"
}

variable "email_bucket" {
  type = "string"
}

variable "spreadsheet_bucket" {
  type = "string"
}

variable "spreadsheet_key" {
  type = "string"
}

variable "sns_topic_arn" {
  type = "string"
}

variable "alarm_arn" {
  type = "string"
}

variable "lambda_name" {
  default = "email-receiver"
}

output "lambda_arn" {
  value = "${aws_lambda_function.email_receiver.arn}"
}

output "lambda_name" {
  value = "${var.lambda_name}"
}

data "terraform_remote_state" "lambda" {
  backend = "s3"

  config {
    profile = "yangmillstheory"
    bucket  = "yangmillstheory-terraform-states"
    region  = "us-west-2"
    key     = "lambda.tfstate"
  }
}

resource "aws_sqs_queue" "email_receiver_deadletter" {
  name = "email_receiver_deadletter"
}

# resource "aws_sqs_queue_policy" "lambda_to_deadletter" {
#   queue_url = "${aws_sqs_queue.email_receiver_deadletter.id}"
#   policy    = "${data.aws_iam_policy_document.sqs_publish.json}"
# }

resource "aws_cloudwatch_metric_alarm" "deadletter_queue_alarm" {
  alarm_name          = "Budget update failed!"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 120
  statistic           = "Sum"
  threshold           = 0

  dimensions = {
    QueueName = "${aws_sqs_queue.email_receiver_deadletter.name}"
  }

  alarm_description         = "Triggers when number of messsages is greater than zero."
  alarm_actions             = ["${var.alarm_arn}"]
  ok_actions                = ["${var.alarm_arn}"]
  insufficient_data_actions = ["${var.alarm_arn}"]

  treat_missing_data = "notBreaching"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "email-receiver/lambda.py"
  output_path = "email-receiver/lambda.zip"
}

# annoying issue here: https://github.com/hashicorp/terraform/issues/15594
resource "aws_s3_bucket_object" "lambda" {
  bucket = "${var.bucket}"
  key    = "${var.key}"
  source = "${data.archive_file.lambda_zip.output_path}"
  etag   = "${data.archive_file.lambda_zip.output_base64sha256}"
}

resource "aws_lambda_function" "email_receiver" {
  function_name     = "${var.lambda_name}"
  s3_bucket         = "${var.bucket}"
  s3_key            = "${var.key}"
  s3_object_version = "${aws_s3_bucket_object.lambda.version_id}"

  dead_letter_config {
    target_arn = "${aws_sqs_queue.email_receiver_deadletter.arn}"
  }

  environment {
    variables = {
      spreadsheet_bucket = "${var.spreadsheet_bucket}"
      spreadsheet_key    = "${var.spreadsheet_key}"
      sns_topic_arn      = "${var.sns_topic_arn}"
      email_bucket       = "${var.email_bucket}"
      email_prefix       = "${var.email_prefix}"
    }
  }

  runtime          = "python3.6"
  role             = "${data.terraform_remote_state.lambda.basic_execution_role_arn}"
  handler          = "lambda.handler"
  source_code_hash = "${data.archive_file.lambda_zip.output_base64sha256}"

  timeout = 300
}

resource "aws_lambda_permission" "ses_invoke" {
  function_name = "${var.lambda_name}"
  action        = "lambda:InvokeFunction"
  principal     = "ses.amazonaws.com"
  statement_id  = "AllowInvokeFromSES"

  depends_on = [
    "aws_lambda_function.email_receiver",
  ]
}
