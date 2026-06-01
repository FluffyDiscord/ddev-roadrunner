<?php
// DDEV add-on infra test: minimal RoadRunner PSR-7 worker (no framework).
require __DIR__ . '/../vendor/autoload.php';

use Nyholm\Psr7\Factory\Psr17Factory;
use Nyholm\Psr7\Response;
use Spiral\RoadRunner\Http\PSR7Worker;
use Spiral\RoadRunner\Worker;

$psr7 = new PSR7Worker(Worker::create(), $f = new Psr17Factory(), $f, $f);

while (($request = $psr7->waitRequest()) !== null) {
    try {
        $psr7->respond(new Response(200, [], 'RoadRunner OK pid=' . getmypid()));
    } catch (\Throwable $e) {
        $psr7->respond(new Response(500, [], (string) $e));
    }
}
