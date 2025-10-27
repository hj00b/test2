// Jenkins Job DSL - GitLab Webhook 통합 설정
// Jenkins UI: New Item > Pipeline > Pipeline script from SCM로 사용

// ========================================
// Backend Pipeline with Generic Webhook Trigger
// ========================================
pipelineJob('backend-deployment-webhook') {
    displayName('Backend Deployment (Webhook)')
    description('GitLab Webhook으로 트리거되는 Backend 배포 파이프라인')

    // Generic Webhook Trigger 설정
    properties {
        pipelineTriggers {
            triggers {
                genericTrigger {
                    // GitLab Webhook에서 파라미터 추출
                    genericVariables {
                        genericVariable {
                            key('GIT_BRANCH')
                            value('$.ref')
                            expressionType('JSONPath')
                            regexpFilter('refs/heads/')
                            defaultValue('')
                        }
                        genericVariable {
                            key('GIT_COMMIT')
                            value('$.checkout_sha')
                            expressionType('JSONPath')
                            defaultValue('')
                        }
                        genericVariable {
                            key('PROJECT_NAME')
                            value('$.project.name')
                            expressionType('JSONPath')
                            defaultValue('')
                        }
                        genericVariable {
                            key('USER_NAME')
                            value('$.user_name')
                            expressionType('JSONPath')
                            defaultValue('')
                        }
                        genericVariable {
                            key('COMMIT_MESSAGE')
                            value('$.commits[0].message')
                            expressionType('JSONPath')
                            defaultValue('')
                        }
                        genericVariable {
                            key('EVENT_TYPE')
                            value('$.object_kind')
                            expressionType('JSONPath')
                            defaultValue('push')
                        }
                    }

                    // Webhook Token (Credentials에 저장된 값)
                    token('gitlab-webhook-secret')

                    // 빌드 트리거 조건
                    regexpFilterText('$GIT_BRANCH')
                    regexpFilterExpression('^(master|dev)$')

                    // 빌드 원인 출력
                    causeString('Triggered by GitLab: $USER_NAME pushed to $GIT_BRANCH')

                    // 콘솔 로그에 파라미터 출력
                    printContributedVariables(true)
                    printPostContent(true)
                }
            }
        }
    }

    // 파이프라인 정의
    definition {
        cpsScm {
            scm {
                git {
                    remote {
                        url('https://gitlab.example.com/group/project.git')
                        credentials('gitlab-credentials')
                    }
                    branches('${GIT_BRANCH}')
                }
            }
            scriptPath('jenkins/pipelines/Jenkinsfile.backend')
        }
    }
}

// ========================================
// Frontend Pipeline with Generic Webhook Trigger
// ========================================
pipelineJob('frontend-deployment-webhook') {
    displayName('Frontend Deployment (Webhook)')
    description('GitLab Webhook으로 트리거되는 Frontend 배포 파이프라인')

    properties {
        pipelineTriggers {
            triggers {
                genericTrigger {
                    genericVariables {
                        genericVariable {
                            key('GIT_BRANCH')
                            value('$.ref')
                            expressionType('JSONPath')
                            regexpFilter('refs/heads/')
                            defaultValue('')
                        }
                        genericVariable {
                            key('GIT_COMMIT')
                            value('$.checkout_sha')
                            expressionType('JSONPath')
                            defaultValue('')
                        }
                        genericVariable {
                            key('USER_NAME')
                            value('$.user_name')
                            expressionType('JSONPath')
                            defaultValue('')
                        }
                    }

                    token('gitlab-webhook-secret')
                    regexpFilterText('$GIT_BRANCH')
                    regexpFilterExpression('^(master|dev)$')
                    causeString('Triggered by GitLab: $USER_NAME pushed to $GIT_BRANCH')
                    printContributedVariables(true)
                }
            }
        }
    }

    definition {
        cpsScm {
            scm {
                git {
                    remote {
                        url('https://gitlab.example.com/group/project.git')
                        credentials('gitlab-credentials')
                    }
                    branches('${GIT_BRANCH}')
                }
            }
            scriptPath('jenkins/pipelines/Jenkinsfile.frontend')
        }
    }
}

// ========================================
// Multi-branch Pipeline (고급 설정)
// ========================================
multibranchPipelineJob('project-multibranch') {
    displayName('Project Multi-branch Pipeline')
    description('모든 브랜치를 자동으로 감지하고 빌드')

    branchSources {
        git {
            id('gitlab-project')
            remote('https://gitlab.example.com/group/project.git')
            credentialsId('gitlab-credentials')

            // 브랜치 필터
            includes('master dev feature/* release/*')
            excludes('hotfix/*')
        }
    }

    // Jenkinsfile 위치
    factory {
        workflowBranchProjectFactory {
            scriptPath('Jenkinsfile')
        }
    }

    // 주기적으로 브랜치 스캔
    triggers {
        periodicFolderTrigger {
            interval('1h')
        }
    }

    // Webhook 트리거 (GitLab Plugin 사용)
    configure { node ->
        node / triggers / 'com.dabsquared.gitlabjenkins.GitLabPushTrigger' {
            spec('')
            triggerOnPush(true)
            triggerOnMergeRequest(true)
            triggerOpenMergeRequestOnPush('never')
            triggerOnNoteRequest(false)
            noteRegex('Jenkins please retry a build')
            skipWorkInProgressMergeRequest(true)
            ciSkip(true)
            setBuildDescription(true)
            branchFilterType('All')
            secretToken('gitlab-webhook-secret')
        }
    }
}

// ========================================
// Folder 구조 (조직화)
// ========================================
folder('GitLab-Projects') {
    displayName('GitLab Projects')
    description('GitLab에서 트리거되는 모든 프로젝트')
}

folder('GitLab-Projects/Backend') {
    displayName('Backend Services')
}

folder('GitLab-Projects/Frontend') {
    displayName('Frontend Applications')
}
