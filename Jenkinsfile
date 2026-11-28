// Jenkins pipeline for Sharp-Account (production, bare metal, no Docker).
//
// Builds the release binary on this server and runs it as the systemd
// service `sharp-account` on 127.0.0.1:7771, behind the reverse proxy that
// serves https://account.sharpnr.com.
//
// What is deployed: only the binary and the env file. Migrations, HTML
// templates, CSS and the favicon are compiled into the binary (sqlx::migrate!,
// Askama, include_str!), so there are no asset folders to copy.
//
// The systemd unit (deploy/sharp-account.service) loads the config with
// EnvironmentFile=${APP_DIR}/.env.production and uses
// WorkingDirectory=${APP_DIR}, which SIGNING_KEYS_DIR=keys is relative to.

pipeline {
    agent any

    environment {
        APP_DIR       = '/opt/apps/sharpnr-account'
        BACKUP_DIR    = '/media/sharpnrllpDrive/sharp-account-engine-backups'
        BINARY_NAME   = 'sharp-account'
        SERVICE_NAME  = 'sharp-account'
        // Group of the service user (deploy/sharp-account.service). This
        // group can read .env.production and the signing keys.
        SERVICE_GROUP = 'sharpnrllp'
        APP_PORT      = '7771'
        PUBLIC_URL    = 'https://account.sharpnr.com'
        // RSA signing keys. Never overwritten by a deploy. Back this folder up:
        // losing it invalidates every issued token.
        KEYS_DIR      = '/opt/apps/sharpnr-account/keys'

        // Keep Cargo's build output outside the workspace, so cleanWs() does
        // not throw away ~300 compiled dependencies on every run.
        CARGO_TARGET_DIR = "${env.JENKINS_HOME}/cargo-target/sharp-account"
        CARGO_TERM_COLOR = 'never'
        // Finds cargo when Rust was installed with rustup for the jenkins user
        // (harmless if it was installed with pacman).
        PATH = "${env.JENKINS_HOME}/.cargo/bin:${env.PATH}"
    }

    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '10'))
        disableConcurrentBuilds()
        timeout(time: 60, unit: 'MINUTES')
    }

    stages {

        // ─────────────────────────────────────────
        // Step 1 — Checkout
        // ─────────────────────────────────────────
        stage('Checkout') {
            steps {
                checkout scm   // pulls main branch as configured in Jenkins job
            }
        }

        // ─────────────────────────────────────────
        // Step 2 — Lint + Test
        // Integration tests need a PostgreSQL user with CREATEDB (each test
        // creates and drops its own database). They run only when the
        // TEST_DATABASE_URL variable is set in Jenkins; otherwise only the
        // unit tests run. Never point it at the production database.
        // ─────────────────────────────────────────
        stage('Lint & Test') {
            steps {
                sh '''
                    echo "▶ Toolchain: $(cargo --version), $(rustc --version)"

                    echo "▶ Checking formatting..."
                    cargo fmt --check || echo "⚠️ Code is not formatted (run 'cargo fmt'). Not blocking."

                    echo "▶ Running clippy..."
                    cargo clippy --locked --all-targets -- -D warnings

                    if [ -n "${TEST_DATABASE_URL:-}" ]; then
                        echo "▶ Running unit + integration tests..."
                        DATABASE_URL="${TEST_DATABASE_URL}" cargo test --locked
                    else
                        echo "⚠️ TEST_DATABASE_URL not set: running unit tests only"
                        cargo test --locked --lib --bins
                    fi
                '''
            }
        }

        // ─────────────────────────────────────────
        // Step 3 — Build the release binary
        // ─────────────────────────────────────────
        stage('Build') {
            steps {
                sh '''
                    echo "▶ Building ${BINARY_NAME} (commit $(git rev-parse --short HEAD))..."
                    cargo build --release --locked --bin ${BINARY_NAME}

                    mkdir -p build
                    cp "${CARGO_TARGET_DIR}/release/${BINARY_NAME}" build/${BINARY_NAME}
                    echo "✅ Built build/${BINARY_NAME} ($(du -h build/${BINARY_NAME} | cut -f1))"
                '''
            }
        }

        // ─────────────────────────────────────────
        // Step 4 — Check the production env file
        // Stored in Jenkins as a "Secret file" credential. Checked before
        // anything on the server is touched, so a bad file fails the build
        // while the running service keeps serving.
        // ─────────────────────────────────────────
        stage('Check Config') {
            steps {
                withCredentials([file(credentialsId: 'sharp-account-env-production', variable: 'ENV_FILE')]) {
                    sh '''
                        value() { grep -E "^$1=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- | tr -d '\\r"'; }

                        echo "▶ Checking .env.production..."

                        grep -Eq '^DATABASE_URL=.+' "$ENV_FILE" || { echo "❌ DATABASE_URL is missing"; exit 1; }

                        PORT_SETTING=$(value PORT)
                        [ "$PORT_SETTING" = "$APP_PORT" ] || { echo "❌ PORT is '$PORT_SETTING', expected $APP_PORT"; exit 1; }

                        ISSUER_SETTING=$(value ISSUER_URL)
                        [ "${ISSUER_SETTING%/}" = "$PUBLIC_URL" ] || { echo "❌ ISSUER_URL is '$ISSUER_SETTING', expected $PUBLIC_URL"; exit 1; }

                        KEYS_SETTING=$(value SIGNING_KEYS_DIR)
                        case "${KEYS_SETTING:-keys}" in
                            keys|"$KEYS_DIR") ;;
                            *) echo "❌ SIGNING_KEYS_DIR is '$KEYS_SETTING', expected 'keys' or $KEYS_DIR"; exit 1 ;;
                        esac

                        HOST_SETTING=$(value HOST)
                        if [ "${HOST_SETTING:-127.0.0.1}" != "127.0.0.1" ]; then
                            echo "⚠️ HOST is '$HOST_SETTING': port $APP_PORT is reachable without the reverse proxy"
                        fi

                        echo "✅ .env.production looks right"
                    '''
                }
            }
        }

        // ─────────────────────────────────────────
        // Step 5 — Deploy binary, env file, signing keys
        // The service keeps running during this stage: replacing the binary
        // with `mv` does not affect the running process. The new binary is
        // picked up by the restart in the next stage.
        // ─────────────────────────────────────────
        stage('Deploy') {
            steps {
                sh '''
                    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
                    mkdir -p ${APP_DIR}

                    # ── Backup ──────────────────────────────────
                    if [ -f ${APP_DIR}/${BINARY_NAME} ]; then
                        echo "▶ Backing up current binary to ${BACKUP_DIR}/${TIMESTAMP}..."
                        mkdir -p ${BACKUP_DIR}/${TIMESTAMP}
                        cp ${APP_DIR}/${BINARY_NAME} ${BACKUP_DIR}/${TIMESTAMP}/${BINARY_NAME}
                        # Tells the failure handler what to roll back to.
                        echo "${BACKUP_DIR}/${TIMESTAMP}" > "${WORKSPACE}/.rollback_from"
                        echo "✅ Backup saved: ${TIMESTAMP}"
                    else
                        echo "▶ No current binary: first deploy, nothing to back up"
                    fi

                    # ── Binary ──────────────────────────────────
                    echo "▶ Installing new binary..."
                    cp build/${BINARY_NAME} ${APP_DIR}/${BINARY_NAME}.new
                    chmod 755 ${APP_DIR}/${BINARY_NAME}.new
                    mv -f ${APP_DIR}/${BINARY_NAME}.new ${APP_DIR}/${BINARY_NAME}
                    echo "✅ Binary installed"

                    # ── Old backup cleanup ───────────────────────
                    echo "▶ Removing backups older than 7 days..."
                    find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true
                '''

                // ── Environment file ────────────────────────
                // The systemd unit loads it with EnvironmentFile=, like
                // sharpnr-engine.
                withCredentials([file(credentialsId: 'sharp-account-env-production', variable: 'ENV_FILE')]) {
                    sh '''
                        echo "▶ Installing .env.production..."
                        cp "$ENV_FILE" ${APP_DIR}/.env.production.new
                        sudo chown jenkins:${SERVICE_GROUP} ${APP_DIR}/.env.production.new
                        sudo chmod 640 ${APP_DIR}/.env.production.new
                        mv -f ${APP_DIR}/.env.production.new ${APP_DIR}/.env.production
                        echo "✅ .env.production installed"
                    '''
                }

                // ── Signing keys ────────────────────────────
                // Creates the first RSA key on the first deploy only. Existing
                // keys are never touched (--if-missing).
                sh '''
                    echo "▶ Checking signing keys in ${KEYS_DIR}..."
                    mkdir -p ${KEYS_DIR}
                    OUTPUT=$(SIGNING_KEYS_DIR=${KEYS_DIR} ${APP_DIR}/${BINARY_NAME} generate-signing-key --if-missing)
                    echo "$OUTPUT"
                    if echo "$OUTPUT" | grep -q "Created signing key"; then
                        echo "⚠️ A new signing key was created. Back up ${KEYS_DIR} now."
                    fi

                    sudo chown -R jenkins:${SERVICE_GROUP} ${KEYS_DIR}
                    sudo chmod 750 ${KEYS_DIR}
                    sudo chmod 640 ${KEYS_DIR}/*.pem
                    echo "✅ Signing keys ready ($(ls ${KEYS_DIR}/*.pem | wc -l) key(s))"
                '''
            }
        }

        // ─────────────────────────────────────────
        // Step 6 — Restart + Verify
        // Startup connects to PostgreSQL and applies pending migrations, then
        // listens. We wait for /health instead of sleeping a fixed time.
        // ─────────────────────────────────────────
        stage('Restart & Verify') {
            steps {
                sh '''
                    START_TIME=$(date "+%Y-%m-%d %H:%M:%S")

                    echo "▶ Restarting ${SERVICE_NAME}..."
                    sudo systemctl stop ${SERVICE_NAME} || true
                    sudo systemctl start ${SERVICE_NAME}

                    # ── Wait for /health ────────────────────────
                    echo "▶ Waiting for http://127.0.0.1:${APP_PORT}/health..."
                    HEALTHY=false
                    for i in $(seq 1 30); do
                        if curl -fsS --max-time 2 http://127.0.0.1:${APP_PORT}/health >/dev/null 2>&1; then
                            echo "✅ Healthy after ${i}s"
                            HEALTHY=true
                            break
                        fi
                        echo "  ⏳ Attempt $i/30..."
                        sleep 1
                    done

                    if [ "$HEALTHY" = false ]; then
                        echo "❌ ${SERVICE_NAME} did not become healthy on port ${APP_PORT} in 30s"
                        sudo systemctl status ${SERVICE_NAME} --no-pager || true
                        journalctl -u ${SERVICE_NAME} --since "$START_TIME" --no-pager -n 50 || true
                        exit 1
                    fi

                    sudo systemctl status ${SERVICE_NAME} --no-pager

                    # ── Issuer check ────────────────────────────
                    # Every token carries this issuer; clients reject a mismatch.
                    echo "▶ Checking the OIDC discovery issuer..."
                    DISCOVERY=$(curl -fsS --max-time 5 http://127.0.0.1:${APP_PORT}/.well-known/openid-configuration) \\
                        || { echo "❌ Discovery document not reachable"; exit 1; }
                    if echo "$DISCOVERY" | grep -q "\\"issuer\\":\\"${PUBLIC_URL}\\""; then
                        echo "✅ Issuer is ${PUBLIC_URL}"
                    else
                        echo "❌ Discovery document does not report issuer ${PUBLIC_URL}"
                        exit 1
                    fi

                    # ── Startup logs ────────────────────────────
                    echo "▶ Checking logs since restart for errors..."
                    if journalctl -u ${SERVICE_NAME} --since "$START_TIME" --no-pager | grep -E "ERROR|panicked"; then
                        echo "❌ Errors found in logs"
                        exit 1
                    else
                        echo "✅ No errors in logs"
                    fi
                '''
            }
        }
    }

    // ─────────────────────────────────────────
    // Post actions
    // ─────────────────────────────────────────
    post {
        success {
            echo "✅ ${SERVICE_NAME} deployed and healthy on 127.0.0.1:${APP_PORT} (${PUBLIC_URL})"
        }
        failure {
            // If the binary was already replaced, put the previous one back
            // before starting the service. Failures before the Deploy stage
            // never stopped the service, so `start` is then a no-op.
            sh '''
                if [ -f "${WORKSPACE}/.rollback_from" ]; then
                    BACKUP_PATH=$(cat "${WORKSPACE}/.rollback_from")
                    echo "❌ Deployment failed — rolling back to ${BACKUP_PATH}..."
                    cp ${BACKUP_PATH}/${BINARY_NAME} ${APP_DIR}/${BINARY_NAME}.new
                    chmod 755 ${APP_DIR}/${BINARY_NAME}.new
                    mv -f ${APP_DIR}/${BINARY_NAME}.new ${APP_DIR}/${BINARY_NAME}
                    sudo systemctl stop ${SERVICE_NAME} || true
                    sudo systemctl start ${SERVICE_NAME} || true
                else
                    echo "❌ Deployment failed — making sure ${SERVICE_NAME} is running..."
                    sudo systemctl start ${SERVICE_NAME} || true
                fi
            '''
        }
        cleanup {
            // `cleanup` runs after `failure`, so the rollback marker above is
            // still there when it is needed.
            cleanWs()
        }
    }
}
