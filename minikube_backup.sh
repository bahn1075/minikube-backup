#!/bin/bash

# 백업 생성 및 복구 스크립트

INCOMPLETE_BACKUP_DIR=${1:-""}
PROFILE_NAME=${2:-minikube}

if [ -z "$INCOMPLETE_BACKUP_DIR" ]; then
    echo "백업을 저장할 경로를 입력하세요:"
    read -p "경로: " base_path
    
    if [ -z "$base_path" ]; then
        echo "경로가 입력되지 않았습니다. 종료합니다."
        exit 1
    fi
    
    # 현재 날짜/시간으로 디렉토리 이름 생성 (YYYYMMDDHHMMSS)
    timestamp=$(date +%Y%m%d%H%M%S)
    INCOMPLETE_BACKUP_DIR="$base_path/minikube-backup-$timestamp"
    
    echo "백업 디렉토리를 생성합니다: $INCOMPLETE_BACKUP_DIR"
    mkdir -p "$INCOMPLETE_BACKUP_DIR"
    
    if [ ! -d "$INCOMPLETE_BACKUP_DIR" ]; then
        echo "백업 디렉토리 생성에 실패했습니다: $INCOMPLETE_BACKUP_DIR"
        exit 1
    fi
fi

if [ ! -d "$INCOMPLETE_BACKUP_DIR" ]; then
    echo "백업 디렉토리가 존재하지 않습니다: $INCOMPLETE_BACKUP_DIR"
    exit 1
fi

echo "=== 백업 시작 ==="
echo "디렉토리: $INCOMPLETE_BACKUP_DIR"
echo "프로필: $PROFILE_NAME"
echo ""

cd "$INCOMPLETE_BACKUP_DIR"

# 현재 상태 확인
echo "=== 현재 백업 상태 확인 ==="
echo "k8s-resources: $(find k8s-resources -name "*.yaml" 2>/dev/null | wc -l) 파일"
echo "helm-backup: $(find helm-backup -name "*.yaml" 2>/dev/null | wc -l) 파일"
echo "volume-data: $(ls volume-data/ 2>/dev/null | wc -l) 파일"
echo "database-backup: $(ls database-backup/ 2>/dev/null | wc -l) 파일"
echo ""

# Secret 디코딩 문제 해결
echo "=== Secret 디코딩 문제 해결 ==="
find k8s-resources/*/secrets-decoded -name "*.error" 2>/dev/null | while read error_file; do
    namespace=$(echo $error_file | cut -d'/' -f2)
    secret_name=$(basename $error_file .error)
    
    echo "재시도: $namespace/$secret_name"
    
    # 수동 base64 디코딩
    {
        echo "=== Secret: $secret_name ==="
        kubectl get secret $secret_name -n $namespace -o json 2>/dev/null | jq -r '.data | to_entries[]? | "\(.key): \(.value)"' | while read key_value; do
            if [ ! -z "$key_value" ]; then
                key=$(echo "$key_value" | cut -d: -f1)
                value=$(echo "$key_value" | cut -d: -f2- | tr -d ' ')
                decoded_value=$(echo "$value" | base64 -d 2>/dev/null || echo "[Binary data or decode failed]")
                echo "$key: $decoded_value"
            fi
        done 2>/dev/null
        echo ""
    } > k8s-resources/$namespace/secrets-decoded/$secret_name.txt
    
    if [ -s k8s-resources/$namespace/secrets-decoded/$secret_name.txt ]; then
        rm -f "$error_file"
        echo "  ✓ $secret_name 복구 완료"
    else
        echo "  ✗ $secret_name 복구 실패"
    fi
done

# 누락된 백업 구성 요소 완성
echo ""
echo "=== 누락된 구성 요소 백업 ==="

# minikube 프로필 백업 (누락시)
if [ ! -d "minikube-profile" ]; then
    echo "minikube 프로필 백업 중..."
    mkdir -p minikube-profile
    rsync -av --exclude='*.log' --exclude='logs/' ~/.minikube/profiles/$PROFILE_NAME/ minikube-profile/ 2>/dev/null || \
    cp -r ~/.minikube/profiles/$PROFILE_NAME/* minikube-profile/ 2>/dev/null || true
fi

# 볼륨 데이터 백업 (누락시)
if [ ! -f "volume-data/all-hostpath-volumes.tar.gz" ]; then
    echo "볼륨 데이터 백업 중..."
    mkdir -p volume-data
    
    # PV/PVC 정보 백업
    kubectl get pv -o yaml > volume-data/persistent-volumes.yaml 2>/dev/null || true
    kubectl get pvc --all-namespaces -o yaml > volume-data/persistent-volume-claims.yaml 2>/dev/null || true
    kubectl get storageclass -o yaml > volume-data/storage-classes.yaml 2>/dev/null || true
    
    # 전체 hostpath-provisioner 백업
    echo "Creating comprehensive hostpath backup..."
    minikube ssh -p $PROFILE_NAME "sudo tar -czf /tmp/all-volumes-backup.tar.gz /tmp/hostpath-provisioner/ 2>/dev/null || echo 'No hostpath volumes found'"
    minikube cp $PROFILE_NAME:/tmp/all-volumes-backup.tar.gz volume-data/all-hostpath-volumes.tar.gz 2>/dev/null || echo "Failed to copy comprehensive volume backup"
    minikube ssh -p $PROFILE_NAME "sudo rm -f /tmp/all-volumes-backup.tar.gz" 2>/dev/null || true
fi

# 데이터베이스 백업 (누락시)
if [ ! -d "database-backup" ] || [ $(ls database-backup/ 2>/dev/null | wc -l) -eq 0 ]; then
    echo "데이터베이스 백업 중..."
    mkdir -p database-backup
    
    # PostgreSQL 백업
    kubectl get pods --all-namespaces -o json | jq -r '.items[] | select(.spec.containers[]?.image | test("postgres|postgresql")) | .metadata.namespace + " " + .metadata.name' | while read namespace pod_name; do
        echo "PostgreSQL 백업: $pod_name in $namespace"
        for user in postgres postgresql root; do
            if kubectl exec $pod_name -n $namespace -- pg_dumpall -U $user > database-backup/postgresql-$pod_name-$namespace-dumpall.sql 2>/dev/null; then
                echo "  ✓ pg_dumpall success with user $user"
                break
            fi
        done 2>/dev/null || echo "  ✗ PostgreSQL backup failed for $pod_name"
    done
fi

# 시스템 정보 백업 (누락시)
if [ ! -d "system-info" ]; then
    echo "시스템 정보 백업 중..."
    mkdir -p system-info
    
    kubectl config view --raw > system-info/kubeconfig.yaml
    kubectl cluster-info > system-info/cluster-info.txt 2>/dev/null || true
    kubectl get nodes -o wide > system-info/nodes-info.txt 2>/dev/null || true
    kubectl version > system-info/kubectl-version.txt 2>/dev/null || true
    
    minikube version > system-info/minikube-version.txt 2>/dev/null || true
    minikube profile list > system-info/minikube-profiles.txt 2>/dev/null || true
    minikube config view -p $PROFILE_NAME > system-info/minikube-config.txt 2>/dev/null || true
    minikube addons list -p $PROFILE_NAME > system-info/minikube-addons.txt 2>/dev/null || true
fi

# 백업 메타데이터 생성
echo ""
echo "=== 백업 메타데이터 업데이트 ==="
cat > backup-metadata.txt << EOF
=== Minikube 클러스터 백업 정보 ===
백업 시간: $(date)
백업 디렉토리: $(basename $(pwd))
프로필 이름: $PROFILE_NAME
Kubernetes 버전: $(kubectl version --short 2>/dev/null | grep Server || echo "Unknown")
minikube 버전: $(minikube version 2>/dev/null || echo "Unknown")
백업 위치: $(pwd)
백업 완료: $(date)

=== 포함된 백업 항목 ===
- Kubernetes 리소스: $(find k8s-resources -name "*.yaml" 2>/dev/null | wc -l) 파일
- Helm Release: $(find helm-backup -name "*.yaml" 2>/dev/null | wc -l) 파일
- Secret 디코딩: $(find k8s-resources/*/secrets-decoded -name "*.txt" 2>/dev/null | wc -l) 파일
- 볼륨 백업: $(find volume-data -name "*.tar.gz" 2>/dev/null | wc -l) 파일
- 데이터베이스 백업: $(find database-backup -type f 2>/dev/null | wc -l) 파일
- minikube 프로필: 설정 및 인증서
- 시스템 정보: 클러스터 상태

=== 백업 과정에서 수행된 작업 ===
- Secret 디코딩 및 저장
- 전체 구성 요소 백업
- 메타데이터 생성

EOF

echo ""
echo "=== 백업 완료 ==="
echo "백업 디렉토리: $(pwd)"
echo ""
echo "백업 내용 요약:"
echo "- Kubernetes 리소스: $(find k8s-resources -name "*.yaml" 2>/dev/null | wc -l) 파일"
echo "- Helm 릴리즈: $(find helm-backup -name "*.yaml" 2>/dev/null | wc -l) 파일"
echo "- Secret 파일: $(find k8s-resources/*/secrets-decoded -name "*.txt" 2>/dev/null | wc -l) 개"
echo "- 볼륨 백업: $(find volume-data -name "*.tar.gz" 2>/dev/null | wc -l) 파일"
echo "- 데이터베이스 백업: $(find database-backup -type f 2>/dev/null | wc -l) 파일"

# 백업 압축 제안
echo ""
read -p "백업을 압축하시겠습니까? (y/N): " compress_confirm
if [[ $compress_confirm == [yY] ]]; then
    cd ..
    backup_name=$(basename "$INCOMPLETE_BACKUP_DIR")
    tar -czf "${backup_name}-recovered.tar.gz" "$backup_name/"
    echo "✓ 압축 완료: ${backup_name}-recovered.tar.gz"
    echo "크기: $(du -sh ${backup_name}-recovered.tar.gz | cut -f1)"
fi

echo ""
echo "백업이 완료되었습니다!"