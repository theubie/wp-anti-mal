<?php
/**
 * Plugin Name: Guard Users (Tripwire)
 * Description: Block known-bad usernames, stop stealth administrator creation, and remove _pre_user_id persistence.
 * Version: 2.0.0
 */

if (!defined('ABSPATH')) {
    exit;
}

function ipm_guard_log($msg) {
    $dir = dirname(ABSPATH) . '/log';
    if (!is_dir($dir)) {
        $dir = WP_CONTENT_DIR;
    }
    $line = '[' . gmdate('c') . '] ' . $msg
        . ' ip=' . (isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : 'cli')
        . ' ua=' . substr(isset($_SERVER['HTTP_USER_AGENT']) ? $_SERVER['HTTP_USER_AGENT'] : 'cli', 0, 180)
        . "\n";
    @file_put_contents($dir . '/ipm-guard.log', $line, FILE_APPEND | LOCK_EX);
}

function ipm_guard_denied_login($login) {
    $login = strtolower((string) $login);
    $exact = array(
        'admin', 'administrator', 'wpadmin', 'test', 'trumpweiss', 'adminbockup',
        'backupadmin', 'itadmin', 'seomanager2026', 'whoadminknows', 'bennett',
        'wpenginebot', 'wp-backup',
    );
    if (in_array($login, $exact, true)) {
        return true;
    }
    $prefixes = array('w2s_', 'wp2_', 'wp2s_', 'wpsvc_', 'nx_', 'wordpress_', 'wp_admin_', 'admin_mg');
    foreach ($prefixes as $prefix) {
        if (strpos($login, $prefix) === 0) {
            return true;
        }
    }
    return false;
}

function ipm_guard_actor_is_trusted_admin() {
    if (defined('WP_CLI') && WP_CLI) {
        return true;
    }
    if (!function_exists('is_user_logged_in') || !is_user_logged_in()) {
        return false;
    }
    return current_user_can('create_users') && current_user_can('promote_users');
}

function ipm_guard_demote_if_untrusted($user_id, $reason) {
    $user = new WP_User((int) $user_id);
    if (!$user->exists() || !in_array('administrator', (array) $user->roles, true)) {
        return;
    }
    if (ipm_guard_actor_is_trusted_admin()) {
        $actor = wp_get_current_user();
        ipm_guard_log("ALLOW admin via $reason user_id={$user->ID} login={$user->user_login} by={$actor->user_login}");
        return;
    }
    $user->set_role(get_option('default_role', 'subscriber'));
    ipm_guard_log("DOWNGRADE via $reason user_id={$user->ID} login={$user->user_login}");
}

add_filter('pre_user_login', function ($login) {
    if (ipm_guard_denied_login($login)) {
        ipm_guard_log("DENY username=$login");
        wp_die('User creation blocked.', 'Forbidden', array('response' => 403));
    }
    return $login;
}, 1);

add_action('user_register', function ($user_id) {
    ipm_guard_demote_if_untrusted($user_id, 'user_register');
}, 999);

add_action('add_user_role', function ($user_id, $role) {
    if ($role === 'administrator') {
        ipm_guard_demote_if_untrusted($user_id, 'add_user_role');
    }
}, 999, 2);

add_action('set_user_role', function ($user_id, $role) {
    if ($role === 'administrator') {
        ipm_guard_demote_if_untrusted($user_id, 'set_user_role');
    }
}, 999, 2);

add_action('updated_user_meta', function ($meta_id, $user_id, $meta_key, $_meta_value) {
    global $wpdb;
    if ($meta_key === $wpdb->prefix . 'capabilities') {
        ipm_guard_demote_if_untrusted($user_id, 'updated_user_meta');
    }
}, 999, 4);

add_action('init', function () {
    $evil_id = get_option('_pre_user_id');
    if (!$evil_id) {
        return;
    }
    delete_option('_pre_user_id');
    require_once ABSPATH . 'wp-admin/includes/user.php';
    wp_delete_user((int) $evil_id);
    ipm_guard_log("BLOCKED _pre_user_id persistence ID=$evil_id");
}, 1);
