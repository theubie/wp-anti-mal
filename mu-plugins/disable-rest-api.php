<?php
/**
 * Plugin Name: Lock XML-RPC and unauthenticated REST
 * Description: Disable XML-RPC. Require login for REST except storefront namespaces that this site actually uses. Never flushes rewrite rules.
 * Version: 2.0.0
 */

if (!defined('ABSPATH')) {
    exit;
}

add_filter('xmlrpc_enabled', '__return_false');

add_action('muplugins_loaded', function () {
    if (empty($_SERVER['SCRIPT_NAME'])) {
        return;
    }
    if (basename($_SERVER['SCRIPT_NAME']) === 'xmlrpc.php') {
        status_header(403);
        header('Content-Type: text/plain; charset=UTF-8');
        echo 'XML-RPC is disabled.';
        exit;
    }
}, 0);

add_action('init', function () {
    remove_action('xmlrpc_rsd_apis', 'rest_output_rsd');
    remove_action('wp_head', 'rest_output_link_wp_head', 10);
    remove_action('template_redirect', 'rest_output_link_header', 11);
}, 1);

/**
 * Public REST prefixes to leave open when the matching plugin is installed.
 */
function ipm_rest_public_prefixes() {
    $prefixes = array();
    $map = array(
        'surecart' => array('/surecart/'),
        'woocommerce' => array('/wc/', '/wc-auth/', '/wc-analytics/'),
        'forminator' => array('/forminator/'),
        'woocommerce-payments' => array('/wc/'),
    );
    foreach ($map as $plugin_dir => $routes) {
        if (is_dir(WP_PLUGIN_DIR . '/' . $plugin_dir)) {
            $prefixes = array_merge($prefixes, $routes);
        }
    }
    return array_unique($prefixes);
}

add_filter('rest_authentication_errors', function ($result) {
    if (!empty($result)) {
        return $result;
    }
    if (is_user_logged_in()) {
        return $result;
    }

    $route = '';
    if (isset($GLOBALS['wp']->query_vars['rest_route'])) {
        $route = (string) $GLOBALS['wp']->query_vars['rest_route'];
    } elseif (!empty($_SERVER['REQUEST_URI'])) {
        $route = (string) $_SERVER['REQUEST_URI'];
    }

    foreach (ipm_rest_public_prefixes() as $prefix) {
        if ($prefix !== '' && strpos($route, $prefix) !== false) {
            return $result;
        }
    }

    return new WP_Error(
        'rest_login_required',
        'REST API requires authentication.',
        array('status' => 401)
    );
});
