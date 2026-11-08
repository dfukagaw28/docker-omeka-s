<?php
/**
 * Omeka S local configuration, driven by environment variables so that the
 * same image can be used on test and production servers.
 */
$env = function (string $name, $default = null) {
    $value = getenv($name);
    return ($value === false || $value === '') ? $default : $value;
};

return [
    'logger' => [
        'log' => filter_var($env('OMEKA_LOG', 'false'), FILTER_VALIDATE_BOOLEAN),
        // To the container log (podman logs / journald) instead of a file
        'path' => 'php://stderr',
        'priority' => constant('\Laminas\Log\Logger::' . strtoupper($env('OMEKA_LOG_PRIORITY', 'NOTICE'))),
    ],
    'http_client' => [
        'sslcapath' => null,
        'sslcafile' => null,
    ],
    'cli' => [
        'phpcli_path' => '/usr/local/bin/php',
    ],
    'thumbnails' => [
        'types' => [
            'large' => ['constraint' => (int) $env('OMEKA_THUMB_LARGE', 800)],
            'medium' => ['constraint' => (int) $env('OMEKA_THUMB_MEDIUM', 200)],
            'square' => ['constraint' => (int) $env('OMEKA_THUMB_SQUARE', 200)],
        ],
        'thumbnailer_options' => [
            'imagemagick_dir' => '/usr/bin',
        ],
    ],
    'translator' => [
        'locale' => $env('OMEKA_LOCALE', 'en_US'),
    ],
    'service_manager' => [
        'aliases' => [
            'Omeka\File\Store' => 'Omeka\File\Store\Local',
            'Omeka\File\Thumbnailer' => 'Omeka\File\Thumbnailer\ImageMagick',
        ],
    ],
];
