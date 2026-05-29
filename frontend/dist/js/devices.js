/**
 * devices.js - 機器管理画面のメインロジック
 * window.api（api.js で公開）を使って機器の CRUD を行う。
 */
(function () {
  'use strict';

  // ===== 状態変数 =====
  let allDevices = [];          // 最後に API から取得した全機器リスト
  let editingId = null;         // 編集中の機器 ID（null = 新規追加）
  let deletingId = null;        // 削除対象の機器 ID
  let filterGroup = '';         // グループフィルタの現在値
  let filterSearch = '';        // 検索フィルタの現在値

  // ===== DOM 参照 =====
  const tbody         = document.getElementById('devices-tbody');
  const deviceCount   = document.getElementById('device-count');
  const filterGroupEl = document.getElementById('filter-group');
  const filterSearchEl= document.getElementById('filter-search');
  const alertArea     = document.getElementById('alert-area');
  const navSystemInfo = document.getElementById('nav-system-info');

  // モーダル関連
  const deviceModalEl = document.getElementById('device-modal');
  const deleteModalEl = document.getElementById('delete-modal');
  const deviceModal   = new bootstrap.Modal(deviceModalEl);
  const deleteModal   = new bootstrap.Modal(deleteModalEl);

  // フォーム要素
  const formDeviceId  = document.getElementById('form-device-id');
  const formIp        = document.getElementById('form-ip');
  const formHostname  = document.getElementById('form-hostname');
  const formName      = document.getElementById('form-name');
  const formGroup     = document.getElementById('form-group');
  const formLocation  = document.getElementById('form-location');
  const formDesc      = document.getElementById('form-description');
  const btnSave       = document.getElementById('btn-save-device');
  const deleteLabel   = document.getElementById('delete-device-label');
  const btnConfirmDel = document.getElementById('btn-confirm-delete');

  // ===== 初期化 =====
  document.addEventListener('DOMContentLoaded', function () {
    loadDevices();
    loadSystemInfo();
    bindEvents();
  });

  // ===== イベントバインド =====
  function bindEvents() {
    // 新規追加ボタン
    document.getElementById('btn-add-device').addEventListener('click', openAddModal);

    // 保存ボタン
    btnSave.addEventListener('click', handleSave);

    // 削除確定ボタン
    btnConfirmDel.addEventListener('click', handleDelete);

    // フィルタ変更
    filterGroupEl.addEventListener('change', function () {
      filterGroup = this.value;
      renderTable(getFilteredDevices());
    });

    filterSearchEl.addEventListener('input', function () {
      filterSearch = this.value.toLowerCase();
      renderTable(getFilteredDevices());
    });

    // Enter キーでフォーム送信
    deviceModalEl.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && e.target.tagName !== 'TEXTAREA') {
        e.preventDefault();
        btnSave.click();
      }
    });
  }

  // ===== データ読み込み =====

  /** 機器一覧を API から取得してテーブルを描画する */
  function loadDevices() {
    showLoading();
    api.listDevices({ limit: 1000 })
      .then(function (devices) {
        allDevices = devices || [];
        updateGroupFilter();
        renderTable(getFilteredDevices());
      })
      .catch(function (err) {
        showAlert('error', '機器一覧の取得に失敗しました: ' + err.message);
        tbody.innerHTML = '<tr><td colspan="6" class="text-center text-muted py-4">' +
                          '<i class="bi bi-exclamation-triangle me-1"></i>データを取得できませんでした</td></tr>';
      });
  }

  /** システム情報をナビバーに表示する */
  function loadSystemInfo() {
    api.getSystemInfo()
      .then(function (info) {
        if (info && info.version) {
          navSystemInfo.textContent = 'v' + info.version;
        }
      })
      .catch(function () {
        // ナビバー表示は任意なので失敗しても無視
      });
  }

  // ===== フィルタリング =====

  /** フィルタ条件に合う機器リストを返す */
  function getFilteredDevices() {
    return allDevices.filter(function (d) {
      const matchGroup  = !filterGroup  || d.group === filterGroup;
      const matchSearch = !filterSearch ||
        (d.ip_address  || '').toLowerCase().includes(filterSearch) ||
        (d.hostname    || '').toLowerCase().includes(filterSearch) ||
        (d.name        || '').toLowerCase().includes(filterSearch) ||
        (d.location    || '').toLowerCase().includes(filterSearch);
      return matchGroup && matchSearch;
    });
  }

  /** グループ select のオプションを最新の機器データで更新する */
  function updateGroupFilter() {
    const groups = Array.from(
      new Set(allDevices.map(function (d) { return d.group; }).filter(Boolean))
    ).sort();

    // 現在の選択値を保持しつつ再描画
    const current = filterGroupEl.value;
    filterGroupEl.innerHTML = '<option value="">すべて</option>';
    groups.forEach(function (g) {
      const opt = document.createElement('option');
      opt.value = g;
      opt.textContent = g;
      if (g === current) opt.selected = true;
      filterGroupEl.appendChild(opt);
    });
  }

  // ===== テーブル描画 =====

  /** 機器一覧テーブルを描画する */
  function renderTable(devices) {
    deviceCount.textContent = devices.length + ' 件';

    if (devices.length === 0) {
      tbody.innerHTML = '<tr class="empty-row"><td colspan="6">' +
        '<i class="bi bi-inbox me-1"></i>機器が登録されていません</td></tr>';
      return;
    }

    tbody.innerHTML = devices.map(function (d) {
      return '<tr>' +
        '<td class="ps-3"><span class="ip-address">' + esc(d.ip_address) + '</span></td>' +
        '<td>' + esc(d.hostname || '—') + '</td>' +
        '<td>' + esc(d.name || '—') + '</td>' +
        '<td>' + (d.group ? '<span class="group-badge">' + esc(d.group) + '</span>' : '<span class="text-muted">—</span>') + '</td>' +
        '<td>' + esc(d.location || '—') + '</td>' +
        '<td class="text-end pe-3">' +
          '<button class="btn btn-outline-primary btn-action btn-action-edit me-1" ' +
                  'data-id="' + d.id + '" data-action="edit" title="編集">' +
            '<i class="bi bi-pencil"></i></button>' +
          '<button class="btn btn-outline-danger btn-action btn-action-delete" ' +
                  'data-id="' + d.id + '" data-action="delete" title="削除">' +
            '<i class="bi bi-trash"></i></button>' +
        '</td>' +
      '</tr>';
    }).join('');

    // 操作ボタンのイベント委譲
    tbody.querySelectorAll('[data-action]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        const id = parseInt(this.dataset.id, 10);
        if (this.dataset.action === 'edit') {
          openEditModal(id);
        } else {
          openDeleteModal(id);
        }
      });
    });
  }

  function showLoading() {
    tbody.innerHTML = '<tr id="loading-row"><td colspan="6" class="text-center text-muted py-4">' +
      '<div class="spinner-border spinner-border-sm me-2" role="status"></div>読み込み中...</td></tr>';
  }

  // ===== モーダル操作 =====

  /** 新規追加モーダルを開く */
  function openAddModal() {
    editingId = null;
    document.getElementById('device-modal-label').innerHTML =
      '<i class="bi bi-plus-circle me-2"></i>機器を追加';
    clearForm();
    clearFormValidation();
    deviceModal.show();
    setTimeout(function () { formIp.focus(); }, 300);
  }

  /** 編集モーダルを開く */
  function openEditModal(id) {
    const device = allDevices.find(function (d) { return d.id === id; });
    if (!device) return;

    editingId = id;
    document.getElementById('device-modal-label').innerHTML =
      '<i class="bi bi-pencil-square me-2"></i>機器を編集';
    clearFormValidation();

    formDeviceId.value  = device.id;
    formIp.value        = device.ip_address  || '';
    formHostname.value  = device.hostname    || '';
    formName.value      = device.name        || '';
    formGroup.value     = device.group       || '';
    formLocation.value  = device.location    || '';
    formDesc.value      = device.description || '';

    deviceModal.show();
    setTimeout(function () { formIp.focus(); }, 300);
  }

  /** 削除確認モーダルを開く */
  function openDeleteModal(id) {
    const device = allDevices.find(function (d) { return d.id === id; });
    if (!device) return;

    deletingId = id;
    const label = [device.ip_address, device.name || device.hostname]
      .filter(Boolean).join(' / ');
    deleteLabel.textContent = label;
    deleteModal.show();
  }

  // ===== CRUD 処理 =====

  /** 保存ボタンの処理（新規追加 or 更新） */
  function handleSave() {
    if (!validateForm()) return;

    const data = {
      ip_address:  formIp.value.trim(),
      hostname:    formHostname.value.trim()  || null,
      name:        formName.value.trim()      || null,
      group:       formGroup.value.trim()     || null,
      location:    formLocation.value.trim()  || null,
      description: formDesc.value.trim()      || null,
    };

    btnSave.disabled = true;
    btnSave.innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>保存中...';

    const promise = editingId
      ? api.updateDevice(editingId, data)
      : api.createDevice(data);

    promise
      .then(function () {
        deviceModal.hide();
        showAlert('success', editingId ? '機器情報を更新しました。' : '機器を追加しました。');
        loadDevices();
      })
      .catch(function (err) {
        showAlert('error', '保存に失敗しました: ' + err.message);
      })
      .finally(function () {
        btnSave.disabled = false;
        btnSave.innerHTML = '<i class="bi bi-check-lg me-1"></i>保存';
      });
  }

  /** 削除確定ボタンの処理 */
  function handleDelete() {
    if (!deletingId) return;

    btnConfirmDel.disabled = true;

    api.deleteDevice(deletingId)
      .then(function () {
        deleteModal.hide();
        showAlert('success', '機器を削除しました。');
        loadDevices();
      })
      .catch(function (err) {
        showAlert('error', '削除に失敗しました: ' + err.message);
        deleteModal.hide();
      })
      .finally(function () {
        btnConfirmDel.disabled = false;
        deletingId = null;
      });
  }

  // ===== バリデーション =====

  /** フォームバリデーション。問題がなければ true を返す */
  function validateForm() {
    clearFormValidation();
    let valid = true;

    // IP アドレス必須 + 形式チェック
    const ip = formIp.value.trim();
    if (!ip) {
      formIp.classList.add('is-invalid');
      valid = false;
    } else if (!isValidIpv4(ip)) {
      formIp.classList.add('is-invalid');
      valid = false;
    } else {
      formIp.classList.add('is-valid');
    }

    return valid;
  }

  /** IPv4 アドレス形式チェック */
  function isValidIpv4(ip) {
    const parts = ip.split('.');
    if (parts.length !== 4) return false;
    return parts.every(function (p) {
      const n = parseInt(p, 10);
      return /^\d+$/.test(p) && n >= 0 && n <= 255;
    });
  }

  function clearFormValidation() {
    [formIp, formHostname, formName, formGroup, formLocation, formDesc]
      .forEach(function (el) {
        el.classList.remove('is-valid', 'is-invalid');
      });
  }

  function clearForm() {
    formDeviceId.value = '';
    formIp.value = '';
    formHostname.value = '';
    formName.value = '';
    formGroup.value = '';
    formLocation.value = '';
    formDesc.value = '';
  }

  // ===== アラート表示 =====

  /**
   * アラートを表示して一定時間後に消す。
   * @param {'success'|'error'|'warning'} type
   * @param {string} message
   */
  function showAlert(type, message) {
    const bsType = type === 'error' ? 'danger' : type;
    const icon   = type === 'error' ? 'exclamation-triangle-fill'
                 : type === 'warning' ? 'exclamation-circle-fill'
                 : 'check-circle-fill';

    const div = document.createElement('div');
    div.className = 'alert alert-' + bsType + ' alert-dismissible fade show';
    div.innerHTML = '<i class="bi bi-' + icon + ' me-2"></i>' + esc(message) +
      '<button type="button" class="btn-close" data-bs-dismiss="alert" aria-label="閉じる"></button>';
    alertArea.prepend(div);

    // 5 秒後に自動消去
    setTimeout(function () {
      const bsAlert = bootstrap.Alert.getOrCreateInstance(div);
      if (bsAlert) bsAlert.close();
    }, 5000);
  }

  // ===== ユーティリティ =====

  /** XSS 防止のために HTML エスケープする */
  function esc(str) {
    if (str == null) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }
})();
