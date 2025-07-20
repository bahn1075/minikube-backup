#!/bin/bash

set -e

# 설정
PROFILE_NAME=${1:-minikube}  # 첫 번째 인자로 프로필 이름, 기본값은 'minikube'
BACKUP_DIR="minikube-full-backup-$(date +%Y%m%d-%H%M%S)"
BACKUP_WITH_VOLUMES=${2:-true}  # 볼륨 데이터 포함 여부

echo "=== Minikube 클러스터 완전 백업 시작 ==="
echo "프로필: $PROFILE_NAME"
echo "백업 디렉토리: $BACKUP_DIR"
echo "볼륨 데이터 포함: $BACKUP_WITH_VOLUMES"

# 백업 디렉토리 생성
mkdir -p $BACKUP_DIR
cd $BACKUP_DIR

# 1. 클러스터 상태 확인
echo "=== 클러스터 상태 확인 ==="
if ! minikube status -p $PROFILE_NAME >/dev/null 2>&1; then
    echo "오류: 프로필 '$PROFILE_NAME'이 존재하지 않거나 실행 중이 아닙니다."
    exit 1
fi

minikube status -p $PROFILE_NAME

# 2. Kubernetes 리소스 백업
echo "=== Kubernetes 리소스 백업 중 ==="

# 모든 네임스페이스의 리소스 백업
kubectl get namespaces -o name | while read ns; do
    namespace=${ns##*/}
    echo "Backing up namespace: $namespace"
    mkdir -p k8s-resources/$namespace
    
    # 각 리소스 타입별 백업
    kubectl get all,configmap,secret,pv,pvc,ingress,networkpolicy,serviceaccount,role,rolebinding \
        --namespace=$namespace -o yaml > k8s-resources/$namespace/all-resources.yaml 2>/dev/null || true
done

# 클러스터 레벨 리소스 백업
echo "Backing up cluster-level resources..."
kubectl get clusterrole,clusterrolebinding,storageclass,persistentvolume,customresourcedefinitions \
    -o yaml > k8s-resources/cluster-resources.yaml 2>/dev/null || true

# 3. Helm Release 백업
echo "=== Helm Release 백업 중 ==="
if command -v helm >/dev/null 2>&1; then
    mkdir -p helm-backup
    
    # Helm 릴리즈 목록
    helm list -A > helm-backup/helm-releases.txt
    
    # 각 릴리즈의 values와 manifest 백업
    helm list -A --output json | jq -r '.[] | "\(.name) \(.namespace)"' 2>/dev/null | while read name namespace; do
        if [ ! -z "$name" ] && [ ! -z "$namespace" ]; then
            echo "Backing up Helm release: $name in $namespace"
            helm get values $name -n $namespace > helm-backup/values-$name-$namespace.yaml 2>/dev/null || true
            helm get manifest $name -n $namespace > helm-backup/manifest-$name-$namespace.yaml 2>/dev/null || true
            helm get hooks $name -n $namespace > helm-backup/hooks-$name-$namespace.yaml 2>/dev/null || true
        fi
    done
else
    echo "Helm이 설치되지 않았습니다. Helm 백업을 건너뜁니다."
fi

# 4. minikube 프로필 백업
echo "=== minikube 프로필 백업 중 ==="
mkdir -p minikube-profile

# 프로필 디렉토리 백업 (실행 중이므로 일부 파일은 복사 안 될 수 있음)
rsync -av --exclude='*.log' --exclude='logs/' ~/.minikube/profiles/$PROFILE_NAME/ minikube-profile/ 2>/dev/null || \
cp -r ~/.minikube/profiles/$PROFILE_NAME/* minikube-profile/ 2>/dev/null || true

# minikube 설정 백업
cp ~/.minikube/config/config.json minikube-profile/minikube-config.json 2>/dev/null || true

# 5. 볼륨 데이터 백업 (PVC 데이터 포함)
if [ "$BACKUP_WITH_VOLUMES" = "true" ]; then
    echo "=== PersistentVolume 데이터 백업 중 ==="
    mkdir -p volume-data
    
    # PV/PVC 정보 백업
    kubectl get pv -o yaml > volume-data/persistent-volumes.yaml 2>/dev/null || true
    kubectl get pvc --all-namespaces -o yaml > volume-data/persistent-volume-claims.yaml 2>/dev/null || true
    kubectl get storageclass -o yaml > volume-data/storage-classes.yaml 2>/dev/null || true
    
    # 각 PVC별 상세 정보 수집
    echo "=== PVC 상세 정보 수집 중 ==="
    kubectl get pvc --all-namespaces -o json > volume-data/pvc-details.json
    
    # PV 사용량 정보
    echo "PV Usage Information:" > volume-data/pv-usage.txt
    kubectl top pods --all-namespaces --containers 2>/dev/null >> volume-data/pv-usage.txt || echo "Metrics not available" >> volume-data/pv-usage.txt
    
    # 실제 데이터 백업 - hostpath-provisioner 전체
    echo "=== 실제 PVC 데이터 백업 중 (이 작업은 시간이 오래 걸릴 수 있습니다) ==="
    
    # hostpath-provisioner 디렉토리 구조 확인
    minikube ssh -p $PROFILE_NAME "ls -la /tmp/hostpath-provisioner/ 2>/dev/null || echo 'No hostpath volumes'" > volume-data/hostpath-structure.txt
    
    # 각 PV별로 개별 백업 (더 안전함)
    kubectl get pv -o json | jq -r '.items[] | select(.spec.hostPath) | .metadata.name + " " + .spec.hostPath.path' | while read pv_name pv_path; do
        echo "Backing up PV: $pv_name at $pv_path"
        
        # PV별 개별 백업
        minikube ssh -p $PROFILE_NAME "sudo tar -czf /tmp/pv-$pv_name.tar.gz '$pv_path' 2>/dev/null || echo 'Failed to backup $pv_name'" 2>/dev/null
        minikube cp $PROFILE_NAME:/tmp/pv-$pv_name.tar.gz volume-data/pv-$pv_name.tar.gz 2>/dev/null || echo "Failed to copy PV backup: $pv_name"
        
        # 임시 파일 정리
        minikube ssh -p $PROFILE_NAME "sudo rm -f /tmp/pv-$pv_name.tar.gz" 2>/dev/null || true
    done
    
    # 전체 hostpath-provisioner 백업 (포괄적 백업)
    echo "Creating comprehensive hostpath backup..."
    minikube ssh -p $PROFILE_NAME "sudo tar -czf /tmp/all-volumes-backup.tar.gz /tmp/hostpath-provisioner/ 2>/dev/null || echo 'No hostpath volumes found'"
    minikube cp $PROFILE_NAME:/tmp/all-volumes-backup.tar.gz volume-data/all-hostpath-volumes.tar.gz 2>/dev/null || echo "Failed to copy comprehensive volume backup"
    
    # 임시 파일 정리
    minikube ssh -p $PROFILE_NAME "sudo rm -f /tmp/all-volumes-backup.tar.gz" 2>/dev/null || true
    
    # Docker 볼륨 백업 (만약 있다면)
    echo "=== Docker 볼륨 백업 확인 중 ==="
    minikube ssh -p $PROFILE_NAME "docker volume ls" > volume-data/docker-volumes.txt 2>/dev/null || echo "No docker volumes"
    
    # 볼륨 마운트 정보
    kubectl get pods --all-namespaces -o json | jq -r '
        .items[] | 
        select(.spec.volumes[]? | .persistentVolumeClaim) |
        .metadata.namespace + "/" + .metadata.name + ": " + 
        (.spec.volumes[] | select(.persistentVolumeClaim) | .name + "=" + .persistentVolumeClaim.claimName)
    ' > volume-data/pod-pvc-mappings.txt 2>/dev/null || echo "No PVC mappings found"
    
    # 백업 크기 정보
    echo "=== 백업 크기 정보 ==="
    ls -lah volume-data/ > volume-data/backup-sizes.txt
    
    echo "볼륨 데이터 백업 완료!"
    echo "백업된 PV 개수: $(ls volume-data/pv-*.tar.gz 2>/dev/null | wc -l || echo 0)"
    echo "전체 볼륨 백업: $(ls -lah volume-data/all-hostpath-volumes.tar.gz 2>/dev/null | awk '{print $5}' || echo 'N/A')"
fi

# 6. 데이터베이스 백업
echo "=== 데이터베이스 백업 중 ==="
mkdir -p database-backup

# PostgreSQL 백업 시도 (일반적인 이름들)
for db_pod in $(kubectl get pods --all-namespaces -o name | grep -E "(postgres|postgresql|database)" | head -5); do
    namespace=$(echo $db_pod | cut -d'/' -f1)
    pod_name=$(echo $db_pod | cut -d'/' -f2)
    
    echo "Attempting to backup database: $pod_name in $namespace"
    kubectl exec $pod_name -n $namespace -- pg_dumpall -U postgres > database-backup/$pod_name-backup.sql 2>/dev/null || \
    kubectl exec $pod_name -n $namespace -- mysqldump --all-databases -u root > database-backup/$pod_name-backup.sql 2>/dev/null || \
    echo "Failed to backup $pod_name (not a standard database or no access)"
done

# 7. 네트워크 및 시스템 정보 백업
echo "=== 시스템 정보 백업 중 ==="
mkdir -p system-info

# kubectl 설정
kubectl config view --raw > system-info/kubeconfig.yaml

# 클러스터 정보
kubectl cluster-info > system-info/cluster-info.txt 2>/dev/null || true
kubectl get nodes -o wide > system-info/nodes-info.txt 2>/dev/null || true
kubectl version > system-info/kubectl-version.txt 2>/dev/null || true

# minikube 정보
minikube version > system-info/minikube-version.txt 2>/dev/null || true
minikube profile list > system-info/minikube-profiles.txt 2>/dev/null || true
minikube config view -p $PROFILE_NAME > system-info/minikube-config.txt 2>/dev/null || true

# 애드온 정보
minikube addons list -p $PROFILE_NAME > system-info/minikube-addons.txt 2>/dev/null || true

# 8. 백업 메타데이터 생성
echo "=== 백업 메타데이터 생성 ==="
cat > backup-metadata.txt << EOF
=== Minikube 클러스터 백업 정보 ===
백업 시간: $(date)
프로필 이름: $PROFILE_NAME
Kubernetes 버전: $(kubectl version --short 2>/dev/null | grep Server || echo "Unknown")
minikube 버전: $(minikube version 2>/dev/null || echo "Unknown")
백업 위치: $(pwd)
볼륨 데이터 포함: $BACKUP_WITH_VOLUMES

=== 포함된 백업 항목 ===
- Kubernetes 리소스 (모든 네임스페이스)
- Helm Release (values, manifests)
- minikube 프로필 설정
- PersistentVolume 데이터 (선택사항)
- 데이터베이스 덤프
- 시스템 및 네트워크 정보

=== 복원 방법 ===
1. 새 minikube 클러스터 생성 또는 기존 클러스터 준비
2. minikube 프로필 복원: cp -r minikube-profile/* ~/.minikube/profiles/[new-profile]/
3. Kubernetes 리소스 복원: kubectl apply -f k8s-resources/
4. Helm 릴리즈 복원: helm install [name] [chart] -f helm-backup/values-[name]-[namespace].yaml
5. 볼륨 데이터 복원: minikube cp volume-data/hostpath-volumes.tar.gz [profile]:/tmp/ && minikube ssh -p [profile] "sudo tar -xzf /tmp/hostpath-volumes.tar.gz -C /"

EOF

# 9. 백업 압축
echo "=== 백업 압축 중 ==="
cd ..
tar -czf $BACKUP_DIR.tar.gz $BACKUP_DIR/

# 10. 완료 메시지
echo ""
echo "=== 백업 완료! ==="
echo "백업 디렉토리: $(pwd)/$BACKUP_DIR"
echo "압축 파일: $(pwd)/$BACKUP_DIR.tar.gz"
echo "백업 크기: $(du -sh $BACKUP_DIR.tar.gz | cut -f1)"
echo ""
echo "백업에 포함된 항목:"
echo "- Kubernetes 리소스: $(find $BACKUP_DIR/k8s-resources -name "*.yaml" | wc -l) 파일"
echo "- Helm 릴리즈: $(find $BACKUP_DIR/helm-backup -name "*.yaml" 2>/dev/null | wc -l || echo 0) 파일"
echo "- minikube 프로필: 설정 및 인증서"
if [ "$BACKUP_WITH_VOLUMES" = "true" ]; then
    echo "- 볼륨 데이터: $(ls -la $BACKUP_DIR/volume-data/hostpath-volumes.tar.gz 2>/dev/null | awk '{print $5}' || echo '0') bytes"
fi
echo ""
echo "복원 시 backup-metadata.txt 파일을 참조하세요."
