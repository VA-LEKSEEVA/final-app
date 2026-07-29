# Final infrastructure

Каталог поднимает базовую инфраструктуру курса одной командой:

- 3 VM в Yandex Cloud;
- внешний Network Load Balancer на 80/443 перед всеми тремя узлами;
- один k3s server и два k3s agent;
- Argo CD и root Application из отдельного GitOps-репозитория;
- Object Storage bucket и отдельный service account для PostgreSQL backup;
- локальные `kubeconfig`, Ansible inventory и pinned `known_hosts`;
- автоматическую проверку nodes, Pods, Argo CD, HTTPS, Grafana, Loki и backup Secret.

Команда не принимает домены `example.*` и другие placeholder-значения.

## Ожидаемый GitOps entrypoint

По умолчанию root Application смотрит в `clusters/prod` ветки `main`.
Этот путь должен создавать дочерние Argo CD Applications для:

1. cert-manager;
2. ingress-nginx;
3. monitoring/kube-prometheus-stack;
4. Loki;
5. guestbook, PostgreSQL и backup CronJob.

GitOps production values должны содержать тот же реальный домен, который
передаётся как `APP_HOST`. Bootstrap также создаёт ConfigMap
`platform-config/final-infra-config` с `APP_HOST` и `GITOPS_REPO_URL` для
диагностики и optional integration. При другой структуре поменяйте
`argocd_root_app_path` и шаблон root Application.

## Предварительная настройка

Установите локально:

- GNU Make;
- Terraform >= 1.6;
- Ansible;
- `kubectl`, `jq`, `curl`, `openssl`;
- Yandex Cloud CLI (`yc`) — нужен также для полной проверки backup bucket.

Авторизуйте Terraform через `yc init` или переменные провайдера. Создайте SSH
ключ, если его нет:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
```

Подготовьте переменные:

```bash
cd final-infra
cp terraform/envs/prod/terraform.tfvars.example \
  terraform/envs/prod/terraform.tfvars
# Впишите реальные cloud_id/folder_id и пути ключей.

cp runtime-secrets.env.example runtime-secrets.env
# Впишите реальные TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID.
# POSTGRES_PASSWORD можно удалить: bootstrap сгенерирует его сам.
```

GitOps-репозиторий должен быть доступен Argo CD. Публичный репозиторий не
требует дополнительных переменных. Для приватного HTTPS-репозитория экспортируйте:

```bash
export GITOPS_USERNAME=oauth2
# Введите токен через скрытый prompt, чтобы он не попал в shell history:
read -s GITOPS_TOKEN
export GITOPS_TOKEN
```

Bootstrap создаст Argo CD repository Secret без вывода токена в команду
`ansible-playbook` или логи.

## Полный прогон

Используйте только реальный домен, которым вы управляете:

```bash
cd final-infra

make nuke

export GITOPS_URL='https://gitlab.com/REAL_ACCOUNT/final-gitops.git'
export APP_HOST='guestbook.REAL_DOMAIN'

make bootstrap \
  GITOPS_URL="$GITOPS_URL" \
  APP_HOST="$APP_HOST"
```

По умолчанию DNS ожидается до 5 минут (`WAIT_DNS_TIMEOUT=300`), а готовность
кластера и Argo CD — до 15 минут (`WAIT_TIMEOUT=900`). Bootstrap ждёт минимум
6 Argo CD Applications (`MIN_ARGO_APPS=6`: root и пять компонентов), чтобы не
принять зелёный root App за полностью развёрнутую платформу. При необходимости:

```bash
make bootstrap ... WAIT_DNS_TIMEOUT=600 WAIT_TIMEOUT=1200 MIN_ARGO_APPS=6
```

`make nuke` безопасно работает и до первого запуска: если локального
Terraform state ещё нет, он только удаляет сгенерированные локальные файлы.

После `terraform apply` можно проверить адрес внешнего Network Load Balancer:

```bash
terraform -chdir=terraform/envs/prod output -raw app_public_ip
```

`APP_HOST` должен указывать на этот адрес до выпуска сертификата Let's Encrypt.
Для первого zero-touch прогона public zone должна находиться в Yandex Cloud DNS,
а `dns_zone_id` должен быть задан в `terraform.tfvars`. Terraform создаст
A-record сам. Внешний DNS нельзя обновить одной командой без API credentials;
поэтому первый bootstrap без `dns_zone_id` намеренно отклоняется.
Повторный `make bootstrap` безопасен: Terraform, Ansible, Secret и Argo CD
применяются идемпотентно.

> Для приватного репозитория задайте `GITOPS_USERNAME` и `GITOPS_TOKEN`;
> токен не передаётся через аргументы командной строки.

GitOps-конфигурация ingress-nginx должна запускать controller с `hostPort` или
`hostNetwork` на портах 80/443. Внешний Yandex Network Load Balancer направляет
трафик на эти порты всех трёх узлов и использует TCP health check.

Terraform state содержит чувствительные S3 credentials. Не публикуйте
`terraform.tfstate`; для командной работы перенесите state в защищённый remote
backend с шифрованием и блокировкой.

## Проверка

`bootstrap` уже выполняет ожидание и автоматический checklist. Повторный запуск:

```bash
make verify APP_HOST="$APP_HOST"
```

Ручные команды:

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes
kubectl get pods -A
kubectl get application -n argocd

kubectl port-forward -n argocd svc/argocd-server 8080:443
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
```

Проверка backup требует авторизованный `yc`, создаёт Job из существующего
CronJob, ждёт завершения и проверяет, что список объектов bucket изменился:

```bash
make backup-check
```

Telegram нельзя достоверно проверить без внешней доставки. Для демонстрации
удалите guestbook Pod и подтвердите alert/recovery сообщения вручную:

```bash
kubectl -n guestbook delete pod -l app.kubernetes.io/name=guestbook
```

## Видео 3–5 минут

1. Покажите `make nuke` и отсутствие VM/локального `kubeconfig`.
2. Запустите `make bootstrap` с реальным `GITOPS_URL` и реальным `APP_HOST`.
3. Ускорьте ожидание Terraform, Ansible и Argo CD.
4. Покажите `kubectl get nodes`, Pods и Applications.
5. Откройте HTTPS-приложение и создайте сообщение.
6. Покажите зелёный Argo CD, Guestbook dashboard и Loki Explore.
7. Запустите `make backup-check`.
8. Сделайте `git push` в GitOps/application repository и покажите обновление
   production после sync.
9. Удалите guestbook Pod и покажите Telegram alert и recovery.

## Удаление

```bash
make nuke
```

Terraform уничтожает только ресурсы из своего state. После успешного destroy
удаляются сгенерированные `kubeconfig`, inventory и `known_hosts`.
