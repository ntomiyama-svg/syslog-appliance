/**
 * api.js - syslog-appliance API クライアント
 * すべての関数を window.api に公開する。
 * ベース URL は相対パス（同じ origin = nginx 経由で FastAPI を叩く）。
 */
(function () {
  'use strict';

  const BASE = '/api/v1';

  /**
   * 共通 fetch ラッパー。
   * - credentials: 'include' でブラウザの Basic 認証情報を送信する
   * - エラー時は response.detail を含む Error を throw する
   */
  async function request(method, path, body) {
    const options = {
      method,
      credentials: 'include',
      headers: {},
    };

    if (body !== undefined) {
      options.headers['Content-Type'] = 'application/json';
      options.body = JSON.stringify(body);
    }

    const res = await fetch(BASE + path, options);

    if (!res.ok) {
      let detail = `HTTP ${res.status}`;
      try {
        const json = await res.json();
        if (Array.isArray(json.detail)) {
          detail = json.detail.map(function (e) {
            const loc = e.loc ? e.loc.slice(1).join('.') : '';
            return loc ? loc + ': ' + e.msg : e.msg;
          }).join(', ');
        } else if (json.detail) {
          detail = json.detail;
        }
      } catch (_) {
        // JSON でない場合はデフォルトメッセージを使う
      }
      throw new Error(detail);
    }

    // 204 No Content などはボディなし
    if (res.status === 204) return null;
    return res.json();
  }

  // ===== 機器管理 API =====

  /**
   * 機器一覧を取得する。
   * @param {Object} filters - { group?: string, search?: string, skip?: number, limit?: number }
   */
  function listDevices(filters) {
    const params = new URLSearchParams();
    if (filters) {
      if (filters.group)  params.set('group', filters.group);
      if (filters.search) params.set('search', filters.search);
      if (filters.skip  !== undefined) params.set('skip',  filters.skip);
      if (filters.limit !== undefined) params.set('limit', filters.limit);
    }
    const qs = params.toString();
    return request('GET', '/devices' + (qs ? '?' + qs : ''));
  }

  /**
   * 機器を 1 件取得する。
   * @param {number} id
   */
  function getDevice(id) {
    return request('GET', `/devices/${id}`);
  }

  /**
   * 機器を新規作成する。
   * @param {Object} data
   */
  function createDevice(data) {
    return request('POST', '/devices', data);
  }

  /**
   * 機器を更新する。
   * @param {number} id
   * @param {Object} data
   */
  function updateDevice(id, data) {
    return request('PUT', `/devices/${id}`, data);
  }

  /**
   * 機器を削除する。
   * @param {number} id
   */
  function deleteDevice(id) {
    return request('DELETE', `/devices/${id}`);
  }

  // ===== システム情報 API =====

  /** システム情報を取得する。 */
  function getSystemInfo() {
    return request('GET', '/system/info');
  }

  // ===== 公開 =====
  window.api = {
    listDevices,
    getDevice,
    createDevice,
    updateDevice,
    deleteDevice,
    getSystemInfo,
  };
})();
