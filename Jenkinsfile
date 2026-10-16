// AIP Deployment Pipeline
//
// Promotes an image that a build pipeline already built, tested and scanned. Nothing is rebuilt.
//
//   Validate -> Approve (sit-02 only) -> Connect -> Deploy (rollout, auto rollback, smoke test) -> Post-deploy tests
//
// Every tool runs in a Docker container (AWS CLI, kubectl), so the Jenkins machine only needs Docker.

pipeline {
    agent any

    options {
        timeout(time: 45, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '50'))
        disableConcurrentBuilds()
    }

    parameters {
        choice(name: 'SERVICE', choices: ['aip-api', 'aip-webapp'], description: 'Microservice to deploy')
        string(name: 'IMAGE_TAG', defaultValue: '', description: 'Image tag from the build pipeline: the git short SHA, e.g. 3f2a1c9')
        choice(name: 'ENVIRONMENT', choices: ['sit-01', 'sit-02'], description: 'Target environment. sit-02 needs an approval')
        choice(name: 'TARGET', choices: ['eks', 'local'], description: 'eks: AWS EKS (aws-credentials). local: a cluster on this machine (kubeconfig-local)')
        booleanParam(name: 'RUN_TESTS', defaultValue: true, description: 'Run the Agentic-qa-demo suites against the environment after deploying')
        string(name: 'TEST_JOB', defaultValue: 'Agentic-qa-demo', description: 'Jenkins job name of the test framework')
        string(name: 'AWS_REGION', defaultValue: 'eu-west-2', description: 'AWS region of the cluster and ECR')
        string(name: 'CLUSTER_NAME', defaultValue: 'aip-mortgage', description: 'EKS cluster name')
    }

    environment {
        PATH = "/Applications/Docker.app/Contents/Resources/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
        AWS_CLI_IMAGE = 'amazon/aws-cli:2.22.0'
        KUBECTL_IMAGE = 'registry.k8s.io/kubectl:v1.35.0'
        // deploy.sh runs kubectl through this wrapper (kubectl in a container)
        KUBECTL = "${WORKSPACE}/scripts/kubectl-docker.sh"
    }

    stages {
        stage('Validate') {
            steps {
                script {
                    if (!(params.IMAGE_TAG ==~ /[0-9a-f]{7,40}/)) {
                        error "IMAGE_TAG must be a git commit SHA from the build pipeline, got '${params.IMAGE_TAG}'"
                    }
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${params.SERVICE}:${params.IMAGE_TAG} → ${params.ENVIRONMENT}"
                }
            }
        }

        stage('Approve') {
            when { expression { params.ENVIRONMENT == 'sit-02' } }
            steps {
                // Before connecting, so the short-lived cluster token isn't spent waiting
                timeout(time: 30, unit: 'MINUTES') {
                    input message: "Deploy ${params.SERVICE}:${params.IMAGE_TAG} to sit-02?", ok: 'Deploy'
                }
            }
        }

        stage('Connect') {
            steps {
                script {
                    if (params.TARGET == 'eks') {
                        withCredentials([usernamePassword(credentialsId: 'aws-credentials', usernameVariable: 'AWS_ACCESS_KEY_ID', passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
                            connectToEks()
                        }
                    } else {
                        withCredentials([file(credentialsId: 'kubeconfig-local', variable: 'LOCAL_KUBECONFIG')]) {
                            sh '''
                                mkdir -p .kube && cp "$LOCAL_KUBECONFIG" .kube/config && chmod 600 .kube/config
                                echo "$SERVICE:$IMAGE_TAG" > .deploy-image
                            '''
                        }
                    }
                    env.DEPLOY_IMAGE = readFile('.deploy-image').trim()
                }
                echo "Deploying ${env.DEPLOY_IMAGE}"
            }
        }

        stage('Deploy') {
            steps {
                sh './scripts/deploy.sh "$SERVICE" "$ENVIRONMENT" "$DEPLOY_IMAGE"'
                script {
                    // Public URL of this environment's frontend (empty until it has a load balancer)
                    env.APP_HOST = sh(returnStdout: true, script: '''
                        "$KUBECTL" -n "$ENVIRONMENT-dip" get svc aip-webapp \
                          -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
                    ''').trim()
                }
            }
        }

        stage('Post-deploy tests') {
            when { expression { params.RUN_TESTS } }
            steps {
                script {
                    if (!env.APP_HOST) {
                        echo "No public URL for ${params.ENVIRONMENT} yet (local cluster, or aip-webapp not deployed), so skipping ${params.TEST_JOB}."
                        echo "Run it by hand with BASE_URL pointing at a port-forward: kubectl -n ${params.ENVIRONMENT}-dip port-forward svc/aip-webapp 8090:80"
                        return
                    }
                    // A new load balancer can take a few minutes before its DNS name resolves
                    sh "for i in \$(seq 1 30); do curl -sf -o /dev/null http://${env.APP_HOST}/healthz && exit 0; sleep 10; done; exit 1"
                    build job: params.TEST_JOB, propagate: true, parameters: [
                        string(name: 'BASE_URL', value: "http://${env.APP_HOST}"),
                        string(name: 'TEST_SUITE', value: params.SERVICE == 'aip-api' ? 'api' : 'smoke')
                    ]
                }
            }
        }
    }

    post {
        success {
            echo "✅ ${params.SERVICE}:${params.IMAGE_TAG} deployed to ${params.ENVIRONMENT}" + (env.APP_HOST ? " (http://${env.APP_HOST})" : '')
        }
        failure {
            echo '❌ Deploy failed. If the rollout or smoke test failed, the previous version was restored automatically.'
        }
        cleanup {
            // The kubeconfig holds a cluster token, so never leave it behind
            sh 'rm -rf .kube .deploy-image k8s/releases'
        }
    }
}

// Promotion gate (the image must already be in ECR), then a kubeconfig with a short-lived EKS token.
// The IAM user behind aws-credentials needs access to the cluster (an EKS access entry).
def connectToEks() {
    sh '''
        AWS="docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION=$AWS_REGION $AWS_CLI_IMAGE"
        ACCOUNT="$($AWS sts get-caller-identity --query Account --output text)"
        REGISTRY="$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com"

        echo "==> Checking $SERVICE:$IMAGE_TAG exists in ECR (only built and scanned images can be deployed)"
        $AWS ecr describe-images --repository-name "$SERVICE" --image-ids imageTag="$IMAGE_TAG" > /dev/null
        echo "$REGISTRY/$SERVICE:$IMAGE_TAG" > .deploy-image

        ENDPOINT="$($AWS eks describe-cluster --name "$CLUSTER_NAME" --query cluster.endpoint --output text)"
        CA="$($AWS eks describe-cluster --name "$CLUSTER_NAME" --query cluster.certificateAuthority.data --output text)"
        TOKEN="$($AWS eks get-token --cluster-name "$CLUSTER_NAME" --query status.token --output text)"

        mkdir -p .kube
        umask 077
        cat > .kube/config <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: eks
    cluster:
      server: $ENDPOINT
      certificate-authority-data: $CA
contexts:
  - name: eks
    context:
      cluster: eks
      user: jenkins
current-context: eks
users:
  - name: jenkins
    user:
      token: $TOKEN
EOF
    '''
}
