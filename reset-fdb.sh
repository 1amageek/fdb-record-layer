#!/bin/bash

# FoundationDB Reset Script
# このスクリプトはFoundationDBを完全にリセットします

set -e

echo "🔄 FoundationDB リセットを開始します..."

# 色付きメッセージ用の関数
info() {
    echo "ℹ️  $1"
}

success() {
    echo "✅ $1"
}

error() {
    echo "❌ $1"
    exit 1
}

# Step 1: FoundationDBサービスを停止
info "Step 1: FoundationDBサービスを停止中..."
if sudo launchctl stop com.foundationdb.fdbmonitor 2>/dev/null; then
    success "FoundationDBサービスを停止しました"
else
    info "サービスは既に停止しているか、停止に失敗しました（続行します）"
fi

sleep 2

# Step 2: プロセスが完全に停止するまで待機
info "Step 2: プロセスの停止を確認中..."
for i in {1..10}; do
    if ! pgrep -f fdbserver > /dev/null; then
        success "すべてのプロセスが停止しました"
        break
    fi
    echo "  待機中... ($i/10)"
    sleep 1
done

# 強制終了が必要な場合
if pgrep -f fdbserver > /dev/null; then
    info "プロセスを強制終了します..."
    sudo killall -9 fdbserver fdbmonitor backup_agent 2>/dev/null || true
    sleep 2
fi

# Step 3: データディレクトリを削除
info "Step 3: データディレクトリを削除中..."
if [ -d "/usr/local/foundationdb/data" ]; then
    sudo rm -rf /usr/local/foundationdb/data/*
    success "データディレクトリを削除しました"
else
    info "データディレクトリが存在しません"
fi

# Step 4: ログディレクトリをクリア（オプション）
info "Step 4: ログディレクトリをクリア中..."
if [ -d "/usr/local/var/log/foundationdb" ]; then
    sudo rm -rf /usr/local/var/log/foundationdb/*
    success "ログディレクトリをクリアしました"
fi

# Step 5: FoundationDBサービスを再起動
info "Step 5: FoundationDBサービスを再起動中..."
if sudo launchctl start com.foundationdb.fdbmonitor; then
    success "FoundationDBサービスを再起動しました"
else
    error "サービスの再起動に失敗しました"
fi

# Step 6: サービスが起動するまで待機
info "Step 6: サービスの起動を待機中..."
for i in {1..30}; do
    if pgrep -f fdbserver > /dev/null; then
        success "FoundationDBサーバーが起動しました"
        break
    fi
    echo "  待機中... ($i/30)"
    sleep 1
done

if ! pgrep -f fdbserver > /dev/null; then
    error "FoundationDBサーバーの起動に失敗しました"
fi

# Step 7: データベースの準備を待機
info "Step 7: データベースの準備を待機中..."
sleep 5

# Step 8: データベースを初期化
info "Step 8: データベースを初期化中..."
if fdbcli --exec "configure new single memory" 2>&1 | grep -q "already exists"; then
    info "データベースは既に存在します。既存の設定を使用します。"
    # 既存のデータベースの設定を確認
    fdbcli --exec "configure single memory"
    success "データベース設定を適用しました"
else
    success "新しいデータベースを初期化しました"
fi

# Step 9: 状態確認
info "Step 9: データベースの状態を確認中..."
sleep 2

if fdbcli --exec "status minimal" | grep -q "available"; then
    success "データベースは正常に動作しています"
    echo ""
    echo "📊 データベースステータス:"
    fdbcli --exec "status minimal"
else
    error "データベースが正常に動作していません"
fi

echo ""
echo "🎉 FoundationDBのリセットが完了しました！"
echo ""
echo "次のステップ:"
echo "  1. テストを実行: swift test"
echo "  2. データベース接続を確認"
echo ""
